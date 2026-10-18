#!/usr/bin/env bash
# test_pipeline_smoke.sh — CPU-only end-to-end smoke test for the Nextflow
# runner (nf-nanopore-basecalling). Runs the REAL main.nf (pod5Id, duplicate-id
# guard, bam2fq/concat wiring) with a deterministic fake-dorado stub, so it
# validates the DAG and the multi-chunk publishDir-overwrite fix with NO GPU,
# NO real dorado, and NO basecalling model.
#
# Requires: nextflow on PATH, pixi + the repo's samtools env (for the barcoded
# path). Run from this directory (or anywhere — the pipeline path is derived).
# Exit: 0 all pass; 1 any failure.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PIPEHOME="$(cd "$HERE" && pwd)"
SAMTOOLS_ENV="$PIPEHOME/envs/samtools/pixi.toml"
readcount() { zcat "$1" 2>/dev/null | awk 'END{print NR/4}'; }

PASSN=0; FAILN=0
pass() { echo "PASS: $*"; PASSN=$((PASSN+1)); }
fail() { echo "FAIL: $*"; FAILN=$((FAILN+1)); }

if ! command -v nextflow >/dev/null; then
  echo "SKIP: nextflow not on PATH — cannot run pipeline e2e"; exit 0
fi

tmp=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# Test-side resource override — mirrors the nanobc-preflight §2.5 convention
# (-c nextflow.config.<env>.local with withLabel: blocks). The shipped local
# profile requests 40 GB for the dorado label; this CPU-only test host has
# less, so the harness overrides all labels to tiny footprints.
cat > "$tmp/test.config" <<'CFG'
process {
    withLabel: 'dorado'   { cpus = 1; memory = '2 GB' }
    withLabel: 'samtools' { cpus = 1; memory = '2 GB' }
    withLabel: 'seqtk'    { cpus = 1; memory = '2 GB' }
}
CFG

# --- fake dorado: valid exit codes and streams, no CUDA ---
cat > "$tmp/bin/dorado" <<FAKE
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then echo "dorado 0.0.0-fake (test stub)"; exit 0; fi
shift   # basecaller
emit_fastq=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -x) shift 2 ;;
    --emit-fastq) emit_fastq=1; shift ;;
    --kit-name)   shift 2 ;;
    *) rest+=("\$1"); shift ;;
  esac
done
pod5="\${rest[1]:-}"
base="\$(basename "\$pod5" .pod5)"    # task stages the chunk under its real name
if [[ -n "\$emit_fastq" ]]; then
  printf '@seq1_chunk=%s\nACGTACGTACGT\n+\nIIIIIIIIIIII\n' "\$base"
  printf '@seq2_chunk=%s\nTTTTGGGGCCCC\n+\nIIIIIIIIIIII\n' "\$base"
  exit 0
fi
samf="\$(mktemp)"
{
  printf '@HD\tVN:1.6\tSO:unsorted\n'
  printf '@SQ\tSN:ctg1\tLN:1000\n'
  printf 'r_bc01_1\t0\tctg1\t10\t60\t12M\t*\t0\t0\tACGTACGTACGT\tIIIIIIIIIIII\tBC:Z:barcode01\n'
  printf 'r_bc01_2\t0\tctg1\t30\t60\t12M\t*\t0\t0\tAACCGGTTAACC\tIIIIIIIIIIII\tBC:Z:barcode01\n'
  printf 'r_unk_1\t0\tctg1\t110\t60\t12M\t*\t0\t0\tTGTGTGTGTGTG\tIIIIIIIIIIII\n'
} > "\$samf"
pixi run --manifest-path $SAMTOOLS_ENV samtools view -b "\$samf"
FAKE
chmod +x "$tmp/bin/dorado"

run_nf() { # args... → run from the sandbox so .nextflow artifacts stay contained
  ( cd "$tmp" && nextflow run "$PIPEHOME/main.nf" \
      -profile local -ansi-log false \
      -c "$tmp/test.config" \
      -work-dir "$tmp/nfwork" "$@" ) >"$tmp/nf.out" 2>&1
}

echo "== 1. LSK path, 3 chunk-split pod5 files — no overwrite =="
mkdir -p "$tmp/model" "$tmp/lskchunks"
for c in 001 002 003; do echo stub > "$tmp/lskchunks/N046.pod5.$c"; done
if run_nf --pod5 "$tmp/lskchunks/N046.pod5.*" --model "$tmp/model" \
          --kitname SQK-LSK114 --outdir "$tmp/out_lsk" --dorado_bin "$tmp/bin/dorado"; then
  pass "nextflow LSK run exit 0"
  n=$(ls "$tmp/out_lsk"/dorado_basecall_lsk/*.fastq.gz 2>/dev/null | wc -l)
  [[ "$n" == "3" ]] && pass "3 DISTINCT chunk fastq.gz in out_lsk/dorado_basecall_lsk" || fail "expected 3 distinct fastq.gz, got $n"
  for c in 001 002 003; do
    [[ -s "$tmp/out_lsk/dorado_basecall_lsk/N046.${c}.fastq.gz" ]] \
      && pass "N046.${c}.fastq.gz published non-empty" \
      || fail "N046.${c}.fastq.gz missing/empty (Path.baseName overwrite regression)"
  done
  [[ "$(readcount "$tmp/out_lsk/dorado_basecall_lsk/N046.002.fastq.gz")" == "2" ]] \
    && pass "each chunk fastq has 2 reads" || fail "chunk read count != 2"
  hdr="$(zcat "$tmp/out_lsk/dorado_basecall_lsk/N046.001.fastq.gz" | sed -n '1p')"
  [[ "$hdr" == "@seq1_chunk=N046.pod5.001" ]] \
    && pass "read header carries the staged chunk name" || fail "unexpected header: '$hdr'"
else
  fail "nextflow LSK run failed: $(tail -8 "$tmp/nf.out")"
fi

echo "== 2. duplicate-id guard fires on colliding chunk names =="
mkdir -p "$tmp/collide/c1" "$tmp/collide/c2"
echo x > "$tmp/collide/c1/read.pod5"; echo x > "$tmp/collide/c2/read.pod5"
if run_nf --pod5 "$tmp/collide/*/*.pod5" --model "$tmp/model" \
          --kitname SQK-LSK114 --outdir "$tmp/out_dup" --dorado_bin "$tmp/bin/dorado"; then
  fail "guard did NOT fire — colliding chunks ran through"
elif grep -q "pod5 id collision" "$tmp/nf.out"; then
  pass "guard aborts with 'pod5 id collision' message"
else
  fail "run failed but not via the id-collision guard: $(tail -5 "$tmp/nf.out")"
fi

echo "== 3. barcoded path, 2 chunks — concat aggregation = per-chunk sums =="
mkdir -p "$tmp/rbkchunks"
for c in 001 002; do echo stub > "$tmp/rbkchunks/rbk_run.pod5.$c"; done
if run_nf --pod5 "$tmp/rbkchunks/rbk_run.pod5.*" --model "$tmp/model" \
          --kitname SQK-RBK114 --outdir "$tmp/out_rbk" --dorado_bin "$tmp/bin/dorado"; then
  pass "nextflow barcoded run exit 0"
  c1="$(readcount "$tmp/out_rbk/fastq/barcode01.fastq.gz")"
  cu="$(readcount "$tmp/out_rbk/fastq/unknown.fastq.gz")"
  [[ "$c1" == "4" ]] && pass "barcode01 = 4 reads (2+2 aggregated across chunks)" \
    || fail "barcode01 != 4 (got '${c1:-missing}') — per-chunk publishDir overwrite regression"
  [[ "$cu" == "2" ]] && pass "unknown = 2 reads (1+1 aggregated across chunks)" \
    || fail "unknown != 2 (got '${cu:-missing}')"
  nbars=$(ls "$tmp/out_rbk"/fastq/*.fastq.gz 2>/dev/null | wc -l)
  [[ "$nbars" == "2" ]] && pass "exactly barcode01 + unknown published (no per-chunk dupes)" \
    || fail "unexpected fastq dir contents: $nbars files"
else
  fail "nextflow barcoded run failed: $(tail -8 "$tmp/nf.out")"
fi

echo
echo "PIPELINE SMOKE TEST: $PASSN pass, $FAILN fail"
[[ $FAILN -eq 0 ]] && exit 0 || exit 1