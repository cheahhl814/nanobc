#!/usr/bin/env bash
# test_smoke.sh — CPU-only structural + functional smoke test for the
# manual (bash) execution path. Requires NO GPU, NO dorado binary, and NO
# basecalling model: the basecaller is exactly the piece the bash path cannot
# exercise without hardware, so this test covers everything around it.
#
# What it checks:
#   1. bash syntax of every recipe script
#   2. the awk demux logic in demux_bam.sh is still in lock-step with
#      modules/dorado.nf (the bam2fq source of truth) — compared after
#      normalizing the Groovy-vs-bash escaping difference (python3 stdlib)
#   3. demux_bam.sh functionally splits a synthetic BAM by BC:Z tags into
#      per-barcode + unknown FASTQs using the pinned samtools pixi env
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
import re, sys

def extract_awk(path, start_pat="awk -v outdir="):
    """Extract the awk program body following start_pat: from the line after
    the marker to the line that is a lone closing single quote."""
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
    # normalize Groovy-vs-bash escaping + whitespace: "\\n"->"\n", "\$i"->$i
    text = "\n".join(body)
    text = text.replace("\\", "")
    return "".join(text.split())

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

# --- 3. functional demux on synthetic BAM (CPU only, pinned samtools pixi env) ---
echo "== 3. functional demux via pinned samtools pixi env =="
if command -v pixi >/dev/null && [[ -f "$SAMTOOLS_ENV" ]]; then
  if pixi run --manifest-path "$SAMTOOLS_ENV" samtools --version >/dev/null 2>&1; then
    pass "samtools pixi env usable"
  else
    fail "samtools pixi env not usable (pixi run --manifest-path $SAMTOOLS_ENV samtools --version failed)"
  fi

  # synthetic SAM: 3x barcode01, 2x barcode02, 1x untagged(unknown) — mapped
  # reads against a 100bp contig, BC:Z tag as the 12th+ optional field
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
    else
      fail "demux_bam.sh non-zero exit: $(cat "$tmp/demux.err")"
    fi
    if [[ -f "$tmp/demux/barcode01.fastq.gz" ]]; then
      readcount() { zcat "$1" 2>/dev/null | awk 'END{print NR/4}'; }
      c1="$(readcount "$tmp/demux/barcode01.fastq.gz")"
      c2="$(readcount "$tmp/demux/barcode02.fastq.gz")"
      cu="$(readcount "$tmp/demux/unknown.fastq.gz")"
      [[ "$c1" == "3" ]] && pass "barcode01 = 3 reads"           || fail "barcode01 count != 3 (got '${c1:-missing}')"
      [[ "$c2" == "2" ]] && pass "barcode02 = 2 reads"           || fail "barcode02 count != 2 (got '${c2:-missing}')"
      [[ "$cu" == "1" ]] && pass "unknown = 1 read"              || fail "unknown count != 1 (got '${cu:-missing}')"
      # sequence + header integrity: first record of barcode01 must match r1
      hdr="$(zcat "$tmp/demux/barcode01.fastq.gz" | sed -n '1p')"
      seq1="$(zcat "$tmp/demux/barcode01.fastq.gz" | sed -n '2p')"
      [[ "$hdr" == "@r1" ]] && pass "read header preserved (@r1)" || fail "header wrong: '$hdr'"
      [[ "$seq1" == "ACGTACGTACGT" ]] && pass "read sequence preserved" || fail "sequence corrupted: got '$seq1'"
    fi
  else
    fail "SAM→BAM conversion failed: $(cat "$tmp/perr")"
  fi
else
  fail "pixi or $SAMTOOLS_ENV missing — cannot run functional demux check"
fi

echo
echo "SMOKE TEST: $PASSN pass, $FAILN fail"
[[ $FAILN -eq 0 ]] && exit 0 || exit 1