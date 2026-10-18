#!/usr/bin/env bash
# test_smoke.sh — CPU-only structural + functional smoke test for the
# manual (bash) execution path. Requires NO GPU, NO real dorado, and NO
# basecalling model: the basecaller is exactly the piece the bash path cannot
# exercise without hardware, so this test covers everything around it with a
# deterministic fake-dorado stub.
#
# Checks:
#   1. bash syntax of every recipe script
#   2. awk demux lock-step with modules/dorado.nf (normalizes Groovy/bash escaping)
#   3. demux_bam.sh on a synthetic BC:Z BAM (pinned samtools pixi env)
#   4. pod5_id() parity with main.nf (chunk-split names must NOT collide) +
#      duplicate-id guard fires
#   5. LSK end-to-end, 3 chunks via fake dorado → 3 DISTINCT published
#      fastq.gz (regression test for the multi-chunk overwrite bug)
#   6. barcoded end-to-end, 2 chunks → per-barcode aggregation = sums
#      (regression test for the bam2fq/concat re-wiring, pipeline v0.1.1)
#
# Usage: ./test_smoke.sh         (run from this directory)
# Exit: 0 all pass; 1 any failure.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
NANOBC_HOME="${NANOBC_HOME:-$(cd "$HERE/../.." && pwd)}"
SAMTOOLS_ENV="$NANOBC_HOME/envs/samtools/pixi.toml"

PASSN=0; FAILN=0
pass() { echo "PASS: $*"; PASSN=$((PASSN+1)); }
fail() { echo "FAIL: $*"; FAILN=$((FAILN+1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- 1. bash syntax ---
echo "== 1. bash syntax =="
for f in "$HERE"/run_basecalling.sh "$HERE"/demux_bam.sh "$HERE"/test_smoke.sh; do
  if bash -n "$f" 2>"$tmp/synerr"; then pass "$(basename "$f")"; else fail "$(basename "$f"): $(cat "$tmp/synerr")"; fi
done

# --- 2. awk demux logic matches modules/dorado.nf (bam2fq source of truth) ---
echo "== 2. awk demux logic matches modules/dorado.nf (normalizing escaping) =="
if python3 - "$NANOBC_HOME/modules/dorado.nf" "$HERE/demux_bam.sh" <<'PYEOF'
import sys

def extract_awk(path, start_pat="awk -v outdir="):
    lines = open(path).read().splitlines()
    try:
        i = next(n for n, l in enumerate(lines) if start_pat in l)
    except StopIteration:
        return None
    body = []
    for l in lines[i + 1:]:
        if l.strip() == "'":
            break
        body.append(l)
    return "".join("\n".join(body).replace("\\", "").split())

nf = extract_awk(sys.argv[1])
rb = extract_awk(sys.argv[2])
if not nf or not rb:
    sys.exit("extraction failed")
sys.exit(0 if nf == rb else "diverged")
PYEOF
then
  pass "awk body identical to modules/dorado.nf bam2fq (post-escape-normalization)"
else
  fail "demux_bam.sh awk diverged from modules/dorado.nf bam2fq — reconcile before shipping"
fi

# --- 3. samtools pixi env + functional demux on synthetic BAM ---
echo "== 3. functional demux via pinned samtools pixi env =="
sam_ok=0
if command -v pixi >/dev/null && [[ -f "$SAMTOOLS_ENV" ]]; then
  if pixi run --manifest-path "$SAMTOOLS_ENV" samtools --version >/dev/null 2>&1; then
    pass "samtools pixi env usable"; sam_ok=1
  else
    fail "samtools pixi env not usable"
  fi
else
  fail "pixi or $SAMTOOLS_ENV missing"
fi

if [[ $sam_ok -eq 1 ]]; then
  cat > "$tmp/synthetic.sam" <<'EOF'
@HD	VN:1.6	SO:unsorted
@SQ	SN:ctg1	LN:1000
r1	0	ctg1	10	60	12M	*	0	0	ACGTACGTACGT	IIIIIIIIIIII	BC:Z:barcode01
r2	0	ctg1	30	60	12M	*	0	0	AACCGGTTAACC	IIIIIIIIIIII	BC:Z:barcode01
r3	0	ctg1	50	60	12M	*	0	0	GGTTAACCGGTT	IIIIIIIIIIII	BC:Z:barcode01
r4	0	ctg1	70	60	12M	*	0	0	TTAAAATTTAAA	IIIIIIIIIIII	BC:Z:barcode02
r5	0	ctg1	90	60	12M	*	0	0	ACACACACACAC	IIIIIIIIIIII	BC:Z:barcode02
r6	0	ctg1	110	60	12M	*	0	0	TGTGTGTGTGTG	IIIIIIIIIIII
EOF
  if pixi run --manifest-path "$SAMTOOLS_ENV" samtools view -b "$tmp/synthetic.sam" -o "$tmp/synthetic.bam" 2>"$tmp/perr"; then
    pass "SAM→BAM conversion ok"
    if bash "$HERE/demux_bam.sh" "$tmp/synthetic.bam" "$tmp/demux" "$SAMTOOLS_ENV" >"$tmp/demux.out" 2>"$tmp/demux.err"; then
      pass "demux_bam.sh exit 0"
      readcount() { zcat "$1" 2>/dev/null | awk 'END{print NR/4}'; }
      # per-chunk files carry the chunk-id prefix (v0.1.1): synthetic_<bc>.fastq.gz
      c1="$(readcount "$tmp/demux/synthetic_barcode01.fastq.gz")"
      c2="$(readcount "$tmp/demux/synthetic_barcode02.fastq.gz")"
      cu="$(readcount "$tmp/demux/synthetic_unknown.fastq.gz")"
      [[ "$c1" == "3" ]] && pass "barcode01 = 3 reads" || fail "barcode01 count != 3 (got '${c1:-missing}')"
      [[ "$c2" == "2" ]] && pass "barcode02 = 2 reads" || fail "barcode02 count != 2 (got '${c2:-missing}')"
      [[ "$cu" == "1" ]] && pass "unknown = 1 read"   || fail "unknown count != 1 (got '${cu:-missing}')"
      hdr="$(zcat "$tmp/demux/synthetic_barcode01.fastq.gz" | sed -n '1p')"
      seq1="$(zcat "$tmp/demux/synthetic_barcode01.fastq.gz" | sed -n '2p')"
      [[ "$hdr" == "@r1" ]] && pass "read header preserved (@r1)" || fail "header wrong: '$hdr'"
      [[ "$seq1" == "ACGTACGTACGT" ]] && pass "read sequence preserved" || fail "sequence corrupted: got '$seq1'"
    else
      fail "demux_bam.sh non-zero exit: $(cat "$tmp/demux.err")"
    fi
  else
    fail "SAM→BAM conversion failed: $(cat "$tmp/perr")"
  fi
fi

# --- 4. pod5_id parity with main.nf + duplicate-id guard ---
echo "== 4. pod5_id() parity with main.nf + duplicate-id guard =="
if eval "$(sed -n '/^pod5_id() {/,/^}/p' "$HERE/run_basecalling.sh")" 2>/dev/null && declare -F pod5_id >/dev/null; then
  check_id() { # name, expected
    got="$(pod5_id "$1")"
    if [[ "$got" == "$2" ]]; then pass "pod5_id($1) == $2"; else fail "pod5_id($1) = '$got', expected '$2'"; fi
  }
  check_id "N046_001.pod5"  "N046_001"
  check_id "N046.pod5.001"  "N046.001"   # chunk-split: NO collision (the fixed bug)
  check_id "N046.pod5.002"  "N046.002"
  check_id "N046.001.pod5"  "N046.001"
  check_id "batch1.pod5"    "batch1"
  if grep -q 'pod5Id' "$NANOBC_HOME/main.nf" && grep -q 'pod5(?=(\\.\\d+)?$)' "$NANOBC_HOME/main.nf"; then
    pass "main.nf pod5Id() regex present (lock-step anchor)"
  else
    fail "main.nf pod5Id() regex drifted — recipe id rule is no longer mirrored"
  fi
else
  fail "could not extract pod5_id() from run_basecalling.sh"
fi

# duplicate-id guard: two dirs, same file name → same id → must die (exit 1)
mkdir -p "$tmp/collide/c1" "$tmp/collide/c2"
echo x > "$tmp/collide/c1/read.pod5"; echo x > "$tmp/collide/c2/read.pod5"
if bash "$HERE/run_basecalling.sh" --pod5 "$tmp/collide/*/*.pod5" --model /tmp --dorado_bin /bin/true >/dev/null 2>"$tmp/coll.err"; then
  fail "duplicate-id guard did NOT fire on colliding chunk names"
elif grep -q "id collision" "$tmp/coll.err"; then
  pass "duplicate-id guard fires with a clear message"
else
  fail "duplicate-id guard died with an unexpected message: $(cat "$tmp/coll.err")"
fi

# --- fake dorado stub for end-to-end recipe runs ---
mkdir -p "$tmp/bin"
cat > "$tmp/bin/dorado" <<FAKE
#!/usr/bin/env bash
# deterministic dorado stub — CPU-only (no CUDA, no model). Emits two FASTQ
# records per invocation (LSK, --emit-fastq) or a synthetic BAM built with the
# repo's real samtools pixi env (barcoded path).
if [[ "\$1" == "--version" ]]; then
  echo "dorado 0.0.0-fake (test stub)"; exit 0
fi
shift   # "basecaller"
emit_fastq=""
rest=()
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -x) shift 2 ;;
    --emit-fastq) emit_fastq=1; shift ;;
    --kit-name)   kitname="\$2"; shift 2 ;;
    *) rest+=("\$1"); shift ;;
  esac
done
model="\${rest[0]:-}"; pod5="\${rest[1]:-}"
base="\$(basename "\$pod5")"
if [[ -n "\$emit_fastq" ]]; then
  printf '@seq1_chunk=%s\nACGTACGTACGT\n+\nIIIIIIIIIIII\n' "\$base"
  printf '@seq2_chunk=%s\nTTTTGGGGCCCC\n+\nIIIIIIIIIIII\n' "\$base"
  exit 0
fi
# barcoded stub: 2x barcode01 + 1 untagged, every run
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
readcount() { zcat "$1" 2>/dev/null | awk 'END{print NR/4}'; }

# --- 5. LSK end-to-end, 3 chunks — DISTINCT published names ---
echo "== 5. LSK e2e (3 chunks, fake dorado) — no overwrite =="
mkdir -p "$tmp/lskmodel" "$tmp/lskchunks_src"
for c in 001 002 003; do echo "stub" > "$tmp/lskchunks_src/N046.pod5.${c}"; done
if bash "$HERE/run_basecalling.sh" \
     --pod5 "$tmp/lskchunks_src/N046.pod5.*" \
     --model "$tmp/lskmodel" --kitname SQK-LSK114 \
     --outdir "$tmp/lskout" --dorado_bin "$tmp/bin/dorado" \
     >"$tmp/lsk.run" 2>&1; then
  pass "run_basecalling.sh LSK exit 0"
  n=$(ls "$tmp/lskout"/dorado_basecall_lsk/*.fastq.gz 2>/dev/null | wc -l)
  [[ "$n" == "3" ]] && pass "3 DISTINCT chunk fastq.gz published" || fail "expected 3 distinct fastq.gz, got $n"
  for c in 001 002 003; do
    [[ -s "$tmp/lskout/dorado_basecall_lsk/N046.${c}.fastq.gz" ]] \
      && pass "N046.${c}.fastq.gz exists + non-empty" \
      || fail "N046.${c}.fastq.gz missing/empty (overwrite regression?)"
  done
  [[ "$(readcount "$tmp/lskout/dorado_basecall_lsk/N046.001.fastq.gz")" == "2" ]] \
    && pass "each chunk fastq has 2 reads" || fail "chunk read count != 2"
else
  fail "run_basecalling.sh LSK e2e failed: $(tail -5 "$tmp/lsk.run")"
fi

# --- 6. barcoded end-to-end, 2 chunks — per-barcode aggregation = sums ---
echo "== 6. barcoded e2e (2 chunks, fake dorado) — aggregation = sums =="
mkdir -p "$tmp/rbkmodel" "$tmp/rbkchunks_src"
for c in 001 002; do echo "stub" > "$tmp/rbkchunks_src/rbk_run.pod5.${c}"; done
if bash "$HERE/run_basecalling.sh" \
     --pod5 "$tmp/rbkchunks_src/rbk_run.pod5.*" \
     --model "$tmp/rbkmodel" --kitname SQK-RBK114 \
     --outdir "$tmp/rbkout" --dorado_bin "$tmp/bin/dorado" \
     >"$tmp/rbk.run" 2>&1; then
  pass "run_basecalling.sh barcoded exit 0"
  c1="$(readcount "$tmp/rbkout/fastq/barcode01.fastq.gz")"
  cu="$(readcount "$tmp/rbkout/fastq/unknown.fastq.gz")"
  [[ "$c1" == "4" ]] && pass "barcode01 aggregated across chunks = 4 reads (2+2)" \
    || fail "barcode01 aggregation wrong: got '${c1:-missing}' (expected 4 — per-chunk overwrite regression?)"
  [[ "$cu" == "2" ]] && pass "unknown aggregated across chunks = 2 reads (1+1)" \
    || fail "unknown aggregation wrong: got '${cu:-missing}' (expected 2)"
  nbams=$(ls "$tmp/rbkout"/rbk_run.*.bam 2>/dev/null | wc -l)
  [[ "$nbams" == "2" ]] && pass "both chunk BAMs kept in outdir" || fail "expected 2 chunk BAMs, got ${nbams:-0}"
else
  fail "run_basecalling.sh barcoded e2e failed: $(tail -5 "$tmp/rbk.run")"
fi

echo
echo "SMOKE TEST: $PASSN pass, $FAILN fail"
[[ $FAILN -eq 0 ]] && exit 0 || exit 1