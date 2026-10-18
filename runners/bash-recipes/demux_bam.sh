#!/usr/bin/env bash
# demux_bam.sh — manual-path equivalent of the `bam2fq` process (modules/dorado.nf).
#
# v1.0.1 — command-for-command mirror of bam2fq: samtools view (pixi env) piped
# into an awk BC:Z-tag splitter, gzipped per barcode. The awk logic here MUST
# stay in lock-step with modules/dorado.nf; diverge only with a matching
# pipeline commit (test_smoke.sh check #2 enforces this).
#
# Usage:
#   ./demux_bam.sh <input.bam> <outdir> [pixi-manifest]
#
#   <pixi-manifest>  default $NANOBC_HOME/runners/nextflow-runner/envs/samtools/pixi.toml
#                    pass an empty string '' to use samtools from $PATH directly
#
# Output: <outdir>/<barcode>.fastq.gz (+ unknown.fastq.gz) — mirrors bam2fq's
# publishDir to ${outdir}/fastq; the caller passes that fastq dir as <outdir>.
#
# Exit codes: 0 ok; 1 validation; 2 demux failure.
set -o errexit
set -o pipefail
set -o nounset

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NANOBC_HOME="${NANOBC_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

BAM="${1:?usage: demux_bam.sh <input.bam> <outdir> [pixi-manifest]}"
OUTDIR="${2:?usage: demux_bam.sh <input.bam> <outdir> [pixi-manifest]}"
PIXI_MANIFEST="${3:-$NANOBC_HOME/runners/nextflow-runner/envs/samtools/pixi.toml}"

[[ -f "$BAM" ]] || { echo "ERROR: no such BAM: $BAM" >&2; exit 1; }
BAM="$(cd "$(dirname "$BAM")" && pwd)/$(basename "$BAM")"

# samtools invocation: through the pinned pixi env when available, PATH fallback otherwise.
if [[ -n "$PIXI_MANIFEST" ]]; then
  [[ -f "$PIXI_MANIFEST" ]] || { echo "ERROR: pixi manifest not found: $PIXI_MANIFEST" >&2; exit 1; }
  command -v pixi >/dev/null || { echo "ERROR: manifest given but pixi is not on PATH" >&2; exit 1; }
  ENVNOTE="samtools via pixi env $PIXI_MANIFEST"
  SAMTOOLS_CMD=(pixi run --manifest-path "$PIXI_MANIFEST" samtools view)
else
  command -v samtools >/dev/null || { echo "ERROR: no manifest given and samtools not on PATH" >&2; exit 1; }
  ENVNOTE="samtools from PATH (no manifest given)"
  SAMTOOLS_CMD=(samtools view)
fi

echo "demux_bam.sh: $BAM -> $OUTDIR ($ENVNOTE)" >&2

# chunk id prefix — mirrors bam2fq's `-v chunk_id="${meta.id}"` (pipeline
# v0.1.1): per-chunk fastq files are `<id>_<barcode>.fastq`, so chunk
# concatenation downstream can group by barcode without staged-name collisions
CHUNK_ID="$(basename "$BAM" .bam)"

# All work happens in a scratch subshell whose cwd plays the role of the
# Nextflow process work dir — the awk program writes relative `fastq_out/`,
# exactly as bam2fq does. Publishing (mv into $OUTDIR) mirrors publishDir.
mkdir -p "$OUTDIR/scratch.$$"
(
  cd "$OUTDIR/scratch.$$"
  mkdir -p fastq_out
  set -o pipefail
  "${SAMTOOLS_CMD[@]}" "$BAM" | \
  awk -v outdir="fastq_out" -v chunk_id="$CHUNK_ID" '
BEGIN { OFS="\n" }
{
    bc="unknown"
    for (i=12; i<=NF; i++) {
        if ($i ~ /^BC:Z:/) {
            bc = substr($i, 6)
            break
        }
    }

    fq = outdir "/" chunk_id "_" bc ".fastq"
    print "@"$1 >> fq
    print $10 >> fq
    print "+" >> fq
    print $11 >> fq
}
'
  gzip -f fastq_out/*.fastq
  mv fastq_out/*.fastq.gz "$OUTDIR"/
) || { echo "ERROR: demux pipeline failed for $BAM (samtools or awk); check BC:Z tags with 'samtools view $BAM | head -1'" >&2; rm -rf "$OUTDIR/scratch.$$"; exit 2; }

rmdir "$OUTDIR/scratch.$$"/fastq_out "$OUTDIR/scratch.$$" 2>/dev/null || true

echo "demux_bam.sh complete:" >&2
for fq in "$OUTDIR"/*.fastq.gz; do
  n="$(zcat "$fq" | awk 'END{print NR/4}')"
  printf '  %-24s %s reads\n' "$(basename "$fq")" "$n"
done
exit 0