---
name: nanobc-qc
description: 'Quality-check a finished nf-nanopore-basecalling run''s output — FASTQ integrity, per-barcode read counts, unclassified fraction, and (for LSK runs) transfer completion. Use after a successful nextflow run when the user wants to know if the basecalling/demux output looks sane.'
version: 2.0.0
updated: "2026-10-18"
triggers:
  - "nanobc QC"
  - "check basecalling output"
  - "did the demux work"
  - "basecalling report"
  - "is my run done"
  - "check demux fastqs"
---

# nanobc-qc — nf-nanopore-basecalling post-run quality control

> **v2.0.0** — restructured into the skill-forge layout: this sub-skill now lives under its phase directory (`preflight/`, `run/`, `debug/`, `qc/`) beneath the skill root (`$NANOBC_HOME`), and the pipeline at `$NANOBC_HOME/runners/nextflow-runner/`. Final phase of the `nanobc-*` bundle: checks a finished run's output integrity (FASTQ integrity, per-barcode base/read counts, unclassified fraction, transfer completion) and writes `$RUN_DIR/report.md`. It never re-runs the pipeline.
>
> **Mode-agnostic (v1.2.1):** QC operates on the output tree, not the executor. The Nextflow runner and the manual bash-recipes path (`run_basecalling.sh`) publish **identical layouts** — LSK: `$OUTDIR/dorado_basecall_lsk/`; barcoded: `$OUTDIR/fastq/` incl. `unknown` — so every check below applies to either mode unchanged. The only mode-dependent bit is failure triage on a QC `FAIL`: route by `params.json:execution_mode` (`manual` → the recipe transcript under `$OUTDIR/logging/`; `nextflow` → `.nextflow.log` + work dirs).

## Audience

This skill serves two purposes:

- **AI Agents**: Triggered by the phrases above. Must run **all** checks that apply to the detected path (§2/§3), then write `report.md` with an overall verdict.
- **Human Users**: Provides a transparent audit trail — `report.md` is the go/no-go record that the run's output is sane and internally consistent.

## When to Use This Skill

Use this skill when:

- A `nextflow run` finished successfully (exit 0) and the user wants to know if the output looks sane
- The user asks "did the demux work" / "is my run done" / "check the demux fastqs"
- A prior run was resumed after a debug fix and the output needs re-verification

Do NOT use this skill if:

- The run failed → `nanobc-debug` first
- No `params.json` exists for this run dir (nothing to locate `$OUTDIR` from) — route via `nanobc-run`
- The user wants biological correctness claims (genome quality, etc.) — this pipeline has no reference or assembly step; QC here is strictly run/output **integrity**

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path | Source | Required? |
| --- | --- | --- |
| `$RUN_DIR/params.json` | `nanobc-preflight` (§0.1) | yes (`kitname`, `outdir`, `transfer_dest`) |
| `$OUTDIR/dorado_basecall_lsk/*.fastq.gz` | pipeline (LSK path, §2) | for LSK runs |
| `$OUTDIR/fastq/*.fastq.gz` | pipeline (barcode path, §3) | for barcode runs |
| `nextflow log` history | `$LAUNCH_DIR` (§0.1) | for transfer-checkpoint lookups |

### Outputs (produced)

| Path | Owner | Format | Notes |
| --- | --- | --- | --- |
| `$RUN_DIR/report.md` | this skill | Markdown | per-check table + **overall** PASS / PASS-WITH-WARNINGS / FAIL |

### Verdict gate

`nanobc-run` **refuses to declare the run good** while `$RUN_DIR/report.md`'s overall verdict is `FAIL` — a `FAIL` hands off to `nanobc-debug` (§6), and `nanobc-preflight` is re-run if the fix changes params. A `report.md` without the **Verdict summary** table (§4) is incomplete and must be regenerated.

### 0.1 Locate the pipeline and the run

```bash
: "${NANOBC_HOME:=$(cd "$SKILL_DIR/../.." 2>/dev/null && pwd)}"
test -f "$NANOBC_HOME/runners/nextflow-runner/main.nf" || { echo "Cannot locate runners/nextflow-runner under the nanobc skill root. Set NANOBC_HOME."; exit 1; }

RUN_DIR="${RUN_DIR:-$NANOBC_HOME}"
OUTDIR=$(jq -r '.outdir' < "$RUN_DIR/params.json" 2>/dev/null || echo "$RUN_DIR/results")
test -d "$OUTDIR" || { echo "No output directory found at $OUTDIR"; exit 1; }

# LAUNCH_DIR = the directory nextflow was launched from; its `.nextflow/` history is what
# `nextflow log` reads (usually $NANOBC_HOME, NOT the artifacts RUN_DIR).
# `nextflow log` takes a run NAME / session id — not a directory path.
: "${LAUNCH_DIR:=$NANOBC_HOME}"
RUN_NAME="${RUN_NAME:-$(cd "$LAUNCH_DIR" && nextflow log -q | tail -1)}"
```

### 0.5 Ask-User Stop Points

This sub-skill has **two** stop points (SP1–SP2). Each fires only when the evidence is ambiguous; the format is **Evidence + Recommend + Options**.

#### SP1 — High unclassified fraction

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| Unclassified fraction ≥ 30% (§3 Check 2) | per-barcode read counts + recorded kit/model from `params.rationale.md` | "Evidence: `<pct>%` unclassified with kit `<kit>` / model `<model>`. Recommend re-running `nanobc-preflight` with a corrected kit/model, then `nextflow run -resume` — or accept if this library is genuinely low-barcode?" |

**Auto-pick when**: < 10% → ✅ expected background, proceed silently. 10–30% → ⚠️ note it in the report, no stop.

#### SP2 — Corrupt / empty FASTQ

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| `gzip -t` fails on one or more FASTQs, or reads == 0 (§2 Check 1 / §3 Check 2) | Which file(s), size, and whether `.command.err` showed a silent early exit | "Re-run the failed task (`-resume`), or invoke `nanobc-debug` on the producing process first?" |

**Auto-pick when**: a single empty/corrupt file with a known fixed cause (e.g. the historical pre-pipefail build, §2 Dorado table in `nanobc-debug`) → recommend `nanobc-debug` + re-run without a stop; otherwise ask.

#### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** When asking, present the evidence first, then the recommendation, then 2–4 concrete options. Do not ask "what do you want?" — ask "I see X, recommend Y, which one of A/B/C?"

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
  # Checkpoint files live in the task work dir; find them via nextflow log (run from LAUNCH_DIR)
  (cd "$LAUNCH_DIR" && nextflow log -f "process,name,status,workdir" "$RUN_NAME") \
    | awk -F'\t' '$1=="transfer"'
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

Output: `$OUTDIR/fastq/<barcode>.fastq.gz` (+ `unknown.fastq.gz`), published
directly from `bam2fq` (`publishDir "${params.outdir}/fastq", mode: 'copy'`).
There is **no `total_bases.tsv`** on the shipped DAG — per-barcode accounting
comes from the FASTQs themselves.

> Note: if you're checking a run from an older build (before `bam2fq`'s
> `publishDir` was added), the per-barcode FASTQs live only in Nextflow's
> `work/` directories — locate them via `(cd "$LAUNCH_DIR" && nextflow log -f "process,name,workdir" "$RUN_NAME") | awk -F'\t' '$1=="bam2fq"'`.

### Check 1 — FASTQ integrity

```bash
for fq in "$OUTDIR"/fastq/*.fastq.gz; do
  gzip -t "$fq" && echo "OK: $fq" || echo "CORRUPT: $fq"
done
```

Same verdicts as the LSK Check 1.

### Check 2 — per-barcode read counts + unclassified fraction

```bash
READS=$(for fq in "$OUTDIR"/fastq/*.fastq.gz; do
  barcode=$(basename "$fq" .fastq.gz)
  n_reads=$(( $(zcat "$fq" | wc -l) / 4 ))
  echo -e "$barcode\t$n_reads"
done)
echo "$READS" | column -t
echo "$READS" | awk -F'\t' '{tot+=$2; if($1=="unknown") unc=$2} END {printf "unclassified_fraction=%.2f%%\n", 100*unc/tot}'
```

| Observation | Verdict |
|---|---|
| Every expected barcode present, non-zero reads, `unknown` < 10% | ✅ |
| A barcode file with 0 reads | ⚠️ that barcode produced no reads — check whether it was actually used in the run, or if demux failed for it |

| Unclassified fraction | Verdict |
|---|---|
| < 10% | ✅ expected background |
| 10–30% | ⚠️ higher than typical — check kit/model match, or that adapters weren't over-trimmed |
| > 30% | ❌ something's off — re-check `--kitname`/`--model` (`nanobc-preflight` §2c/d), or this simply wasn't a barcoded library |

There is no fixed "correct" threshold — these bands are a rough sanity check, not a validated ONT specification. Treat them as a prompt to look closer, not a hard pass/fail.

### Check 3 — cross-checks

- `unknown.fastq.gz` reads ≫ any real barcode's reads → a demux outcome, not a script bug (see the `bam2fq` rows in `nanobc-debug` §2).
- A barcode with many reads but a suspiciously small `.fastq.gz` → possible truncation — worth a closer look at `bam2fq`'s awk demux logic (`modules/dorado.nf:90-104`).

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
| Read counts | ✅ / ⚠️ / ❌ | <summary> |
| Unclassified fraction (barcode path) | ✅ / ⚠️ / ❌ | <pct> |
| Transfer completion (LSK + transfer_dest only) | ✅ / ⚠️ / ❌ / n/a | <evidence> |

**Overall**: <PASS / PASS-WITH-WARNINGS / FAIL>

## Evidence

### per-barcode read counts (barcode path) or per-file read counts (LSK path)
\`\`\`
<raw output>
\`\`\`

## Notes & recommended follow-ups
- <bullet list of any warnings/failures, with concrete next steps — e.g. "re-run nanobc-preflight with a corrected --model", or "invoke nanobc-debug on the transfer process">

## Reproducibility
- params.json: $RUN_DIR/params.json
- dorado version: <from params.rationale.md if available, else "not recorded — re-run nanobc-preflight next time">
- envs/samtools, envs/seqtk pixi.lock: $NANOBC_HOME/runners/nextflow-runner/envs/*/pixi.lock
- this report: $RUN_DIR/report.md (regenerable via `nanobc-qc` skill)
```

## 5. What NOT to do

- Do **not** re-run the pipeline to "fix" issues — produce a report, let the user decide
- Do **not** invent a biological-correctness claim (e.g. "this looks like a good genome") — this pipeline has no reference or assembly step; QC here is strictly about output integrity and internal consistency
- Do **not** treat the unclassified-fraction bands in §3 Check 3 as a validated specification — they're a heuristic prompt to look closer, say so explicitly in the report
- Do **not** write to `$NANOBC_HOME/...` paths — only `$RUN_DIR/...` and `$OUTDIR/...` (which is itself user-configured, may or may not be under `$NANOBC_HOME`)

## Troubleshooting — Signature library

When a QC evidence step itself fails, match against these patterns. **Always** read the actual error before concluding.

| Signature in stderr | Likely cause | Suggested fix |
| --- | --- | --- |
| `nextflow log -q` prints nothing (§0.1) | No run history in `$LAUNCH_DIR` — run launched from a different dir, or never launched | Confirm the launch dir with the user (`.nextflow.log` must exist there); if it never ran, this skill is premature → `nanobc-run` |
| `No such file or directory` on `$RUN_DIR/params.json` | Preflight artifact absent for this run dir | Route to `nanobc-preflight`; never guess `$OUTDIR` |
| `jq: parse error` on `params.json` | Truncated/hand-edited params file | Re-run `nanobc-preflight` — do **not** hand-patch the JSON |
| `gzip: invalid compressed data` (but `gzip -t` was already the check) | Corrupt/truncated FASTQ — a Check verdict, not a tool failure | Record as ❌ in the report (SP2, §0.5) |
| `zcat` / `gzip` / `ssh` / `rsync` / `nextflow`: `command not found` | Tool missing on the QC host | Install the missing tool; the checks are read-only and safe to re-run after |
| `Permission denied (publickey)` during the transfer-completion check (§2 Check 2) | SSH key for `$TRANSFER_DEST` host not set up from *this* host | Note in report; distinguish from a transfer-process failure (which is `nanobc-debug`'s) |
| `fastq/` missing though the run "finished" (§3) | Wrong `$OUTDIR` from `params.json`, or an LSK kit that mis-routed to the barcode path | Cross-check `kitname` routing (§1) and `outdir`; if wrong, re-run `nanobc-preflight` |

## Interpretation Guidelines

The overall verdict written into `report.md` (§4):

- **PASS**: all applicable checks ✅ — FASTQs intact and non-empty, counts internally consistent, unclassified fraction < 10%, transfer (if any) completed.
- **PASS-WITH-WARNINGS**: at least one ⚠️ check (e.g. 10–30% unclassified, a barcode with zero bases that was genuinely unused, untested-band observations). Proceed, but surface the warnings to the user.
- **FAIL**: at least one ❌ check — corrupt/truncated FASTQ, transfer silently incomplete, unclassified fraction > 30%. **Do not** declare the run good; hand off to `nanobc-debug` (§6).

The §3 threshold bands (e.g. 10%/30% unclassified) are **heuristic sanity prompts, not a validated ONT specification** — say so explicitly in the report's notes.

## Verification

- [ ] `$RUN_DIR/report.md` exists with the Verdict summary table, per-check results, raw evidence, and an **Overall** line of `PASS` / `PASS-WITH-WARNINGS` / `FAIL`.
- [ ] Every check that fired has its raw command output quoted in the Evidence section (not summarized away).
- [ ] The path type (`lsk` vs `barcode`) was derived from `params.json`'s `kitname` (§1) and the matching check set was fully run — LSK checks for LSK, barcode checks for barcode.
- [ ] Dorado version is stated in the Reproducibility section (from `params.rationale.md` if available; otherwise flagged as "not recorded — re-run `nanobc-preflight` next time").
- [ ] No pipeline re-run was executed to "fix" anything; any recommended fix is delegated to `nanobc-debug` / `nanobc-preflight` in §6.

## 6. Handoff

- If unclassified fraction is high or a barcode is missing entirely → recommend the user re-invoke `nanobc-preflight` with a corrected `--kitname`/`--model`, then re-run (mode per `params.json:execution_mode`: `nextflow run -resume`, or `run_basecalling.sh` for the manual path)
- If FASTQ integrity fails (corrupt file) or a process didn't complete → hand off to `nanobc-debug`
- If everything passes → point the user to `$RUN_DIR/report.md` and the published outputs under `$OUTDIR`

The recommended handoff message:

> nanobc-qc complete. Wrote `$RUN_DIR/report.md` — overall verdict: `<PASS | PASS-WITH-WARNINGS | FAIL>`. <One-line summary of the checks>. Next: `<nanobc-debug` + re-run | re-run `nanobc-preflight` with corrected params | done — your outputs are under `$OUTDIR>`.
