#!/usr/bin/env bash
# run_basecalling.sh — manual (bash) execution path for nf-nanopore-basecalling
#
# v1.0.0 — mirrors modules/dorado.nf + main.nf command-for-command. The Nextflow
# pipeline (nextflow run main.nf) remains the source of truth; this script is a
# thin executor for single-machine / no-Nextflow / smoke situations. If a
# process script in modules/dorado.nf changes, mirror the change here in the
# same commit.
#
# Two paths, selected by --kitname exactly like main.nf:
#   LSK kits      (kitname contains "LSK", e.g. SQK-LSK114):
#       dorado basecaller -x "cuda:all" --emit-fastq MODEL POD5 | gzip > <id>.fastq.gz
#       → published to   $OUTDIR/dorado_basecall_lsk/<id>.fastq.gz
#   Barcoded kits (e.g. SQK-RBK114):
#       dorado basecaller -x "cuda:all" --kit-name KIT MODEL POD5 > <id>.bam
#       then bam2fq demultiplexing (awk on BC:Z tags) via samtools (pixi env)
#       → published to   $OUTDIR/fastq/<barcode>.fastq.gz (+ unknown.fastq.gz)
# Optional (LSK only): --transfer_dest user@host:/path mirrors the `transfer`
#   process (ssh mkdir + rsync), skipped when unset.
#
# Usage:
#   ./run_basecalling.sh --pod5 "input_folder/N046/*.pod5" \
#                        --model /path/to/dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
#                        [--kitname SQK-LSK114] [--outdir ./results] \
#                        [--dorado_bin dorado] [--transfer_dest user@host:/p/] \
#   or: ./run_basecalling.sh --params-file params.json   # keys as in main.nf
#
# Exit codes: 0 ok; 1 usage/validation; 2 demux failure; 3 transfer failure.
set -o errexit
set -o pipefail
set -o nounset

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '/^$/d'; exit 1; }
die() { echo "ERROR: $*" >&2; exit 1; }

POD5="" MODEL="" KITNAME="SQK-LSK114" OUTDIR="${PWD}/results" DORADO_BIN="dorado" TRANSFER_DEST="" PARAMS_FILE=""
NANOBC_HOME="${NANOBC_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# normalise a params.json / flag value: strip surrounding quotes, expand ~
norm() {
  local v="$1"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  v="${v/#\~/$HOME}"
  printf '%s' "$v"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pod5)          POD5="$(norm "$2")"; shift 2 ;;
    --model)         MODEL="$(norm "$2")"; shift 2 ;;
    --kitname)       KITNAME="$(norm "$2")"; shift 2 ;;
    --outdir)        OUTDIR="$(norm "$2")"; shift 2 ;;
    --dorado_bin)    DORADO_BIN="$(norm "$2")"; shift 2 ;;
    --transfer_dest) TRANSFER_DEST="$(norm "$2")"; shift 2 ;;
    --params-file)   PARAMS_FILE="$(norm "$2")"; shift 2 ;;
    -h|--help)       usage ;;
    *)               die "unknown argument: $1 (see --help)" ;;
  esac
done

# --params-file: map params.json keys (main.nf schema) onto the flag variables.
# Flags already given on the command line win over file values.
if [[ -n "$PARAMS_FILE" ]]; then
  command -v jq >/dev/null || die "--params-file requires jq"
  [[ -f "$PARAMS_FILE" ]] || die "--params-file: no such file: $PARAMS_FILE"
  for k in pod5 model kitname outdir dorado_bin transfer_dest; do
    v="$(jq -r --arg k "$k" '.[$k] // empty' < "$PARAMS_FILE")"
    if [[ -n "$v" && "$v" != "null" ]]; then
      eval "$k=\"\$(norm \"\$v\")\""
    fi
  done
fi

# --- validation (mirrors main.nf's missing-param check + checkIfExists) ---
[[ -n "$POD5"  ]] || die "missing required value: --pod5 (or .pod5 in --params-file)"
[[ -n "$MODEL" ]] || die "missing required value: --model (or .model in --params-file)"

command -v "$DORADO_BIN" >/dev/null 2>&1 || [[ -x "$DORADO_BIN" ]] \
  || die "dorado binary '$DORADO_BIN' not resolvable — install it on PATH or pass --dorado_bin <abs path>"

mapfile -t POD5_FILES < <(compgen -G "$POD5" || true)
[[ ${#POD5_FILES[@]} -gt 0 ]] \
  || die "pod5 glob matches nothing: $POD5 (main.nf would abort via checkIfExists: true)"
[[ -e "$MODEL" ]] || die "model path does not exist: $MODEL"

NANOBC_HOME="$(cd "$NANOBC_HOME" && pwd)"
[[ -d "$NANOBC_HOME/envs" ]] \
  || echo "WARN: $NANOBC_HOME does not look like the nf-nanopore-basecalling tree — pixi env lookups for samtools will fail on the barcoded path" >&2
SAMTOOLS_ENV="$NANOBC_HOME/envs/samtools/pixi.toml"

TS="$(date +%Y-%m-%d_%H-%M-%S)"
LOGFILE="$OUTDIR/logging/manual_run_${TS}.log"
mkdir -p "$OUTDIR/logging"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOGFILE"; }

DORADO_VERSION="$("$DORADO_BIN" --version 2>/dev/null | head -n1 || echo unknown)"
log "manual run: pod5=$POD5 (${#POD5_FILES[@]} files) model=$MODEL kitname=$KITNAME outdir=$OUTDIR"
log "dorado: $DORADO_VERSION (unpinned stand-alone ONT binary — record this in params.rationale.md)"

# --- optional post-hoc transfer, mirroring the `transfer` process (LSK only) ---
transfer_lsk() {
  local fq="$1"
  log "transfer: rsync $fq -> $TRANSFER_DEST"
  echo "$TRANSFER_DEST" | tr ":" " " | while read -r prompt dir; do
    ssh "$prompt" "mkdir -p $dir"
  done
  if ! rsync -r --progress "$fq" "$TRANSFER_DEST"; then
    log "transfer failed for $fq"
    return 3
  fi
}

LSK=0; [[ "$KITNAME" == *LSK* ]] && LSK=1

# --- per-file driver, mirroring dorado_basecall_lsk / dorado_basecall ---
for pod5_file in "${POD5_FILES[@]}"; do
  id="$(basename "$pod5_file")"
  id="${id%.*}"                                  # meta.id = baseName in main.nf

  if [[ $LSK -eq 1 ]]; then
    outfq="$OUTDIR/dorado_basecall_lsk/${id}.fastq.gz"
    mkdir -p "$(dirname "$outfq")"
    log "basecall (LSK): $pod5_file"
    # NOTE: set -o pipefail mirrors the historical pipefail fix in modules/dorado.nf —
    # without it a failed dorado underneath `| gzip` silently "succeeds".
    if ! "$DORADO_BIN" basecaller -x "cuda:all" \
         --emit-fastq "$MODEL" "$pod5_file" 2>>"$LOGFILE" | gzip > "$outfq"; then
      die "dorado basecaller failed on $pod5_file (see $LOGFILE)"
    fi
    # empty-output guard: with pipefail inherited, exit 0 guarantees gzip saw data,
    # but check anyway — the empty-fastq failure mode is this pipeline's #1 gotcha
    [[ -s "$outfq" ]] || die "output $outfq is EMPTY — dorado likely produced nothing; see $LOGFILE"
    log "wrote $outfq ($(du -h "$outfq" | cut -f1))"
    if [[ -n "$TRANSFER_DEST" ]]; then
      transfer_lsk "$outfq" || exit 3
    fi
  else
    outbam="$OUTDIR/${id}.bam"
    mkdir -p "$(dirname "$outbam")"
    log "basecall (barcoded): $pod5_file"
    if ! "$DORADO_BIN" basecaller -x "cuda:all" \
         --kit-name "$KITNAME" \
         "$MODEL" "$pod5_file" > "$outbam" 2>>"$LOGFILE"; then
      die "dorado basecaller failed on $pod5_file (see $LOGFILE)"
    fi
    log "wrote $outbam ($(du -h "$outbam" | cut -f1)); demultiplexing ..."
    mkdir -p "$OUTDIR/fastq"
    bash "$SCRIPT_DIR/demux_bam.sh" "$outbam" "$OUTDIR/fastq" "$SAMTOOLS_ENV" \
      || die "demux_bam.sh failed on $outbam (exit 2 = demux failure)"
  fi
done

log "manual run complete; outputs under $OUTDIR"
if [[ $LSK -ne 1 ]]; then
  ls "$OUTDIR/fastq" 2>/dev/null | sed 's/^/  /'
fi
exit 0