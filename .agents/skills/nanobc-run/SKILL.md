---
name: nanobc-run
description: Run nf-nanopore-basecalling end-to-end, including applying any user-side nextflow.config override. Use when a user wants to basecall pod5 files and may not know the full workflow. Walks them through preflight → nextflow run → qc/debug. Triggers: "run the basecalling pipeline", "basecall this pod5 folder", "I have pod5 files", "nanobc run", "start a basecalling run", "dorado pipeline", "nextflow config local machine basecalling".
---

# nanobc-run — nf-nanopore-basecalling end-to-end orchestrator

This skill is a thin router. It does not duplicate logic from the other three `nanobc-*` skills. Its job is to ask: **"what stage is the user at, and which skill should they invoke next?"**

## 0. Resolve the pipeline and run directory

Same convention as the other skills: `$NANOBC_HOME` env var, or sibling `../nf-nanopore-basecalling`.

```bash
: "${NANOBC_HOME:=$(cd "$SKILL_DIR/../../../nf-nanopore-basecalling" 2>/dev/null && pwd)}"
test -f "$NANOBC_HOME/main.nf" || { echo "Cannot locate nf-nanopore-basecalling. Set NANOBC_HOME."; exit 1; }

# Run dir is wherever the user wants params.json / reports to live.
# Recommend a dedicated dir per sample/flow cell (e.g. runs/N046), not $NANOBC_HOME itself,
# since this pipeline is typically re-run many times against different pod5 batches.
: "${RUN_DIR:=$NANOBC_HOME}"
```

## 1. Determine the user's stage

Try to detect automatically **before** asking:

```bash
OUTDIR=$(jq -r '.outdir // empty' < "$RUN_DIR/params.json" 2>/dev/null)

# total_bases.tsv exists → barcode-path run finished successfully
if [ -n "$OUTDIR" ] && [ -f "$OUTDIR/total_bases.tsv" ]; then
    STAGE="qc"
# LSK FASTQ output exists → LSK-path run finished successfully
elif [ -n "$OUTDIR" ] && ls "$OUTDIR"/dorado_basecall_lsk/*.fastq.gz >/dev/null 2>&1; then
    STAGE="qc"
# A diagnosis already exists → debug done, walk through it
elif [ -f "$RUN_DIR/diagnosis.md" ]; then
    STAGE="review-diagnosis"
# Params ready → ready to run
elif [ -f "$RUN_DIR/params.json" ]; then
    STAGE="run"
# Nothing yet → preflight
else
    STAGE="preflight"
fi
```

If auto-detection is ambiguous (e.g. `params.json` exists but no `.nextflow.log` — unclear if it ever ran), ask one short question:

> Are you starting a new run, or continuing a previous one?
>
> - new run (no params.json yet)
> - I have params.json already, haven't run it
> - I just ran it and it failed
> - I just ran it successfully

## 2. Route to the right skill

| Stage              | Action                                                                                                |
| ------------------ | ------------------------------------------------------------------------------------------------------ |
| `preflight`        | Invoke `nanobc-preflight`. It produces `params.json` and the run command. Come back here when done.    |
| `run`              | Show the run command (see §3). Get explicit confirmation. Then run.                                   |
| `debug`            | Invoke `nanobc-debug`. It writes `diagnosis.md`. Come back when done.                                  |
| `qc`               | Invoke `nanobc-qc`. It writes `report.md`.                                                             |
| `review-diagnosis` | Read `$RUN_DIR/diagnosis.md` with the user, recommend Option A from its "Recommended next action" block. |

**Do not skip preflight.** Even if the user supplies params manually, recommend running `nanobc-preflight` first — it's the only place Dorado's version and the kit/model choices get validated and recorded (Dorado has no pixi/conda pin, so this audit trail matters more here than for the pixi-managed tools).

## 3. The run command (only fires at the `run` stage)

### Detect the user-side config override

`nanobc-preflight` may have written a `nextflow.config.<env>.local` file next to `params.json` (see `nanobc-preflight` §2.5). `-c` layers it *on top of* `$NANOBC_HOME/nextflow.config`. Always check before running:

```bash
: "${NANOBC_PROFILE:=slurm}"   # or "local"
USER_CONFIG="$RUN_DIR/nextflow.config.${NANOBC_PROFILE}.local"
if [ -f "$USER_CONFIG" ]; then
  echo "Applying user-side override: $USER_CONFIG"
  CONFIG_FLAG="-c $USER_CONFIG"
else
  echo "No user override found at $USER_CONFIG — using $NANOBC_HOME/nextflow.config defaults"
  echo "(defaults hardcode --partition=highprio --gres=gpu:3g.39gb:1 for the 'dorado' label under -profile slurm;"
  echo " if this cluster doesn't have that partition/gres, run nanobc-preflight first.)"
  CONFIG_FLAG=""
fi
```

### Show the user the command

```bash
cd "$NANOBC_HOME"

# Local (workstation with a CUDA GPU) — with override if present:
nextflow run main.nf -profile local $CONFIG_FLAG -params-file "$RUN_DIR/params.json"

# SLURM (cluster) — with override if present:
nextflow run main.nf -profile slurm $CONFIG_FLAG -params-file "$RUN_DIR/params.json"
```

Ask: **"This will start a Nextflow run with the params above. OK to proceed? (yes / no / dry-run)"**

### Recommend dry-run for first-time users

```bash
nextflow run main.nf -profile slurm $CONFIG_FLAG -params-file "$RUN_DIR/params.json" -dry-run
```

Shows the planned DAG and resolved per-process `cpus`/`memory`/`clusterOptions` without submitting anything — a quick way to confirm a config override is actually being picked up, and to catch a bad `pod5` glob (via `checkIfExists: true`) before it reaches the scheduler.

### Resume is a separate, distinct command

If the user says "I already ran this, just resume", do NOT use the bare `nextflow run` command:

```bash
nextflow run main.nf -profile slurm $CONFIG_FLAG -params-file "$RUN_DIR/params.json" -resume
```

`-resume` picks up cached completed tasks from `.nextflow/` and re-runs only what failed or changed. If the user changed the override (e.g. bumped the `dorado` label's `memory` or fixed the partition/gres) between the failed and resumed run, `-resume` will retry the failed task with the new settings — always suggest it as the *first* retry after a failure.

## 4. After the run

| Outcome                                        | Next skill                                        |
| ----------------------------------------------- | -------------------------------------------------- |
| Exit 0, `total_bases.tsv` or LSK FASTQ exists    | `nanobc-qc`                                        |
| Exit non-zero, no `diagnosis.md`                 | `nanobc-debug`                                     |
| `diagnosis.md` already exists                    | walk the user through Option A from it             |
| User says "looks good" after QC                  | done — point them to `$RUN_DIR/report.md` and `$OUTDIR/` |

After invoking any next-step skill, **explicitly hand off** — don't make the user discover the next action. Example:

> I've handed off to `nanobc-qc`. It will check the output FASTQs and per-barcode base counts, then write `report.md` to your run directory. Say the word and I'll invoke it.

## 5. Important rules

- **Never** run the pipeline without explicit user confirmation
- **Never** edit `params.json` after preflight — if values are wrong, re-run `nanobc-preflight`
- **Always** recommend `-dry-run` for first-time users (unless they explicitly say "just run it")
- **Always** offer to invoke the next skill — don't leave the user to find it
- **Never** run two nextflow runs in the same `$RUN_DIR` concurrently — `-resume` cannot disambiguate them. If the user wants to start over, move `.nextflow/` aside first or use a new run directory.
- **If `$NANOBC_HOME` doesn't resolve, ask** before guessing. A wrong pipeline home = wasted GPU time.
- **Recommend a run directory per sample/flow cell** (e.g. `runs/<sample>/`), not reusing `$NANOBC_HOME` itself — this pipeline is normally re-run repeatedly against different pod5 batches, and the existing `params/example.json` (`transfer_dest: .../dorado7/N046/`) is itself an example of a per-sample output path.

## 6. Output contract — no artifact

This skill produces **no file** of its own. Its only outputs are:

- The run command (printed to the user)
- The hand-off message naming the next skill

All artifacts (`params.json`, `diagnosis.md`, `report.md`) are produced by the other three skills. Don't try to write them from here.

## 7. Common follow-ups

| User says                       | What to do                                                                                          |
| -------------------------------- | ----------------------------------------------------------------------------------------------------- |
| "Looks good" after QC             | Summarize: kitname/path taken, output location, key QC verdicts                                       |
| "Can I trust this output?"        | Point them to `$RUN_DIR/report.md` and `$RUN_DIR/params.rationale.md` — both are audit-trail artifacts |
| "I want to run more samples"      | Recommend a new `$RUN_DIR` per sample; `$NANOBC_HOME` (the pipeline) can be shared across all of them |
| "How do I cite this?"             | `cat "$NANOBC_HOME/README.md"`                                                                          |
