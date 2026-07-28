---
name: nanobc-qc
description: Quality-check a finished nf-nanopore-basecalling run's output — FASTQ integrity, per-barcode read/base counts, unclassified fraction, and (for LSK runs) transfer completion. Use after a successful nextflow run when the user wants to know if the basecalling/demux output looks sane. Triggers: "nanobc QC", "check basecalling output", "did the demux work", "basecalling report", "is my run done", "check total_bases.tsv".
---

# nanobc-qc — nf-nanopore-basecalling post-run quality control

This skill runs **after** a successful `nextflow run`. It never re-runs the pipeline. Unlike an assembly pipeline, there is no reference genome or biological ground truth here — QC means **run/output integrity**: did basecalling and demultiplexing complete, are the FASTQ files intact, and do the base/read counts look internally consistent.

## 0. Locate the pipeline and the run

```bash
: "${NANOBC_HOME:=$(cd "$SKILL_DIR/../../../nf-nanopore-basecalling" 2>/dev/null && pwd)}"
test -f "$NANOBC_HOME/main.nf" || { echo "Cannot locate nf-nanopore-basecalling. Set NANOBC_HOME."; exit 1; }

RUN_DIR="${RUN_DIR:-$NANOBC_HOME}"
OUTDIR=$(jq -r '.outdir' < "$RUN_DIR/params.json" 2>/dev/null || echo "$RUN_DIR/results")
test -d "$OUTDIR" || { echo "No output directory found at $OUTDIR"; exit 1; }
```

## 1. Identify which path ran

```bash
KITNAME=$(jq -r '.kitname' < "$RUN_DIR/params.json")
case "$KITNAME" in
  *LSK*) PATH_TYPE="lsk" ;;
  *)     PATH_TYPE="barcode" ;;
esac
echo "kitname=$KITNAME -> $PATH_TYPE path"
```

## 2. LSK path checks

Output: `$OUTDIR/dorado_basecall_lsk/<sample>.fastq.gz` (published), plus `<sample>.checkpoint` files if `--transfer_dest` was set (checkpoints are written to the Nextflow work dir, not published — locate via `nextflow log`).

### Check 1 — FASTQ integrity and basic stats

```bash
for fq in "$OUTDIR"/dorado_basecall_lsk/*.fastq.gz; do
  gzip -t "$fq" && echo "OK: $fq" || echo "CORRUPT: $fq"
  n_reads=$(( $(zcat "$fq" | wc -l) / 4 ))
  echo "  reads=$n_reads"
done
```

| Observation | Verdict |
|---|---|
| `gzip -t` passes, reads > 0 | ✅ |
| `gzip -t` passes, reads == 0 | ⚠️ empty output — check Dorado log for silent early exit |
| `gzip -t` fails (corrupt/truncated) | ❌ re-run this sample (`-resume` will re-execute a task whose output failed validation only if Nextflow itself detected the failure; a corrupt-but-"complete" file needs a manual re-run of that task) |

### Check 2 — transfer completion (only if `--transfer_dest` was set)

```bash
TRANSFER_DEST=$(jq -r '.transfer_dest' < "$RUN_DIR/params.json")
if [ -n "$TRANSFER_DEST" ]; then
  # Checkpoint files live in the task work dir; find them via nextflow log
  nextflow log -f "process,name,status,workdir" "$RUN_DIR" | awk -F'\t' '$1=="transfer"'
  # Then, for a COMPLETED transfer task:
  ls "$WORKDIR"/*.checkpoint 2>/dev/null && echo "checkpoint present"
  # Confirm the file actually landed remotely:
  DEST_HOST=$(echo "$TRANSFER_DEST" | cut -d: -f1)
  DEST_PATH=$(echo "$TRANSFER_DEST" | cut -d: -f2-)
  ssh "$DEST_HOST" "ls -la '$DEST_PATH'" 2>&1
fi
```

| Observation | Verdict |
|---|---|
| Checkpoint exists AND remote `ls` shows the fastq.gz with a plausible size | ✅ transferred |
| Checkpoint exists, remote file missing/0 bytes | ❌ transfer silently incomplete — re-run `transfer` process (`-resume`) |
| No checkpoint, `transfer` process shows non-COMPLETED | see `nanobc-debug` |

## 3. Barcode-demux path checks

Output: `$OUTDIR/fastq/<barcode>.fastq.gz` (published — see note below) and `$OUTDIR/total_bases.tsv`.

> Note: `concat_fastq` publishes to `$OUTDIR/fastq/`. If you're checking a run from **before** this publishDir was added to `modules/dorado.nf`, the per-barcode FASTQs will only exist in Nextflow's `work/` directories — locate them via `nextflow log -f "process,name,workdir" "$RUN_DIR" | awk -F'\t' '$1=="concat_fastq"'`.

### Check 1 — `total_bases.tsv` sanity

```bash
cat "$OUTDIR/total_bases.tsv"
```

| Observation | Verdict |
|---|---|
| One row per barcode + `unclassified`, all with non-zero `total_bases` | ✅ |
| A barcode row with `total_bases` == 0 or empty | ⚠️ that barcode produced no reads — check whether it was actually used in the run, or if demux failed for it |
| `unclassified` >> any real barcode's total | ⚠️/❌ depending on magnitude — see Check 3 |

### Check 2 — FASTQ integrity

```bash
for fq in "$OUTDIR"/fastq/*.fastq.gz; do
  gzip -t "$fq" && echo "OK: $fq" || echo "CORRUPT: $fq"
done
```

Same verdicts as the LSK Check 1.

### Check 3 — unclassified fraction

```bash
awk -F'\t' 'NR>1 {tot+=$2; if($1=="unclassified") unc=$2} END {printf "unclassified_fraction=%.2f%%\n", 100*unc/tot}' "$OUTDIR/total_bases.tsv"
```

| Unclassified fraction | Verdict |
|---|---|
| < 10% | ✅ expected background |
| 10–30% | ⚠️ higher than typical — check kit/model match, or that adapters weren't over-trimmed |
| > 30% | ❌ something's off — re-check `--kitname`/`--model` (`nanobc-preflight` §2c/d), or this simply wasn't a barcoded library |

There is no fixed "correct" threshold — these bands are a rough sanity check, not a validated ONT specification. Treat them as a prompt to look closer, not a hard pass/fail.

### Check 4 — read-count cross-check per barcode

```bash
for fq in "$OUTDIR"/fastq/*.fastq.gz; do
  barcode=$(basename "$fq" .fastq.gz)
  n_reads=$(( $(zcat "$fq" | wc -l) / 4 ))
  echo -e "$barcode\t$n_reads"
done
```

Compare against `total_bases.tsv`'s per-barcode base totals — a barcode with many reads but very low total bases suggests reads are being truncated somewhere upstream (worth a closer look at `bam2fq`'s awk demux logic in `modules/dorado.nf:76-101`).

## 4. Output contract — write `report.md`

Always write to `$RUN_DIR/report.md`:

```markdown
# nf-nanopore-basecalling QC report

Run dir:   $RUN_DIR
Path:      lsk | barcode
Pipeline:  $NANOBC_HOME
Generated: <ISO8601>

## Verdict summary

| Check | Result | Notes |
|---|---|---|
| FASTQ integrity | ✅ / ⚠️ / ❌ | <n files, n corrupt> |
| Read/base counts | ✅ / ⚠️ / ❌ | <summary> |
| Unclassified fraction (barcode path only) | ✅ / ⚠️ / ❌ | <pct> |
| Transfer completion (LSK + transfer_dest only) | ✅ / ⚠️ / ❌ / n/a | <evidence> |

**Overall**: <PASS / PASS-WITH-WARNINGS / FAIL>

## Evidence

### total_bases.tsv (barcode path) or per-file read counts (LSK path)
\`\`\`
<raw output>
\`\`\`

## Notes & recommended follow-ups
- <bullet list of any warnings/failures, with concrete next steps — e.g. "re-run nanobc-preflight with a corrected --model", or "invoke nanobc-debug on the transfer process">

## Reproducibility
- params.json: $RUN_DIR/params.json
- dorado version: <from params.rationale.md if available, else "not recorded — re-run nanobc-preflight next time">
- envs/samtools, envs/seqtk pixi.lock: $NANOBC_HOME/envs/*/pixi.lock
- this report: $RUN_DIR/report.md (regenerable via `nanobc-qc` skill)
```

## 5. What NOT to do

- Do **not** re-run the pipeline to "fix" issues — produce a report, let the user decide
- Do **not** invent a biological-correctness claim (e.g. "this looks like a good genome") — this pipeline has no reference or assembly step; QC here is strictly about output integrity and internal consistency
- Do **not** treat the unclassified-fraction bands in §3 Check 3 as a validated specification — they're a heuristic prompt to look closer, say so explicitly in the report
- Do **not** write to `$NANOBC_HOME/...` paths — only `$RUN_DIR/...` and `$OUTDIR/...` (which is itself user-configured, may or may not be under `$NANOBC_HOME`)

## 6. When to invoke other skills

- If unclassified fraction is high or a barcode is missing entirely → recommend the user re-invoke `nanobc-preflight` with a corrected `--kitname`/`--model`, then `nextflow run -resume`
- If FASTQ integrity fails (corrupt file) or a process didn't complete → hand off to `nanobc-debug`
- If everything passes → point the user to `$RUN_DIR/report.md` and the published outputs under `$OUTDIR`
