---
name: nanobc-run
description: 'Run nf-nanopore-basecalling end-to-end in either execution mode: the Nextflow runner (default for HPC/cluster/cohort runs, trace reports) or the manual bash-recipes path (single-machine, no-Nextflow situations). Includes applying any user-side nextflow.config override. Use when a user wants to basecall pod5 files and may not know the full workflow. Walks them through preflight → run (mode-selected) → qc/debug. Router: invoked directly by these triggers or by handoff from the other nanobc-* skills.'
version: 1.2.0
updated: "2026-10-18"
triggers:
  - "run the basecalling pipeline"
  - "basecall this pod5 folder"
  - "I have pod5 files"
  - "nanobc run"
  - "start a basecalling run"
  - "dorado pipeline"
  - "nextflow config local machine basecalling"
  - "basecall without nextflow"
  - "manual basecalling"
  - "run basecalling bash"
---

# nanobc-run — nf-nanopore-basecalling end-to-end orchestrator

> **v1.2.0.** Thin router for the `nanobc-*` skill family: detects the user's stage from filesystem evidence, offers the execution-mode fork (§0.6a), routes to the right skill/path, and hands off explicitly.

## Audience

This skill serves two purposes:

- **AI Agents**: Triggered by the phrases above. Must detect the stage from filesystem evidence **before** asking, route to the right skill, and hand off explicitly.
- **Human Users**: A predictable entry point that always answers "which phase runs next, and what artifact will it produce?"

## When to Use This Skill

Use this skill when:

- The user says "run the basecalling pipeline" / "basecall this pod5 folder" without naming a phase
- A run is in flight and the user wants to preview, resume, or monitor it
- It is unclear which of the four `nanobc-*` skills applies right now

Do NOT use this skill if:

- The user only wants params prepared → invoke `nanobc-preflight` directly
- The user reports a concrete failure and wants it interpreted → `nanobc-debug`
- A run finished successfully and the user only wants QC → `nanobc-qc`

## 0. Orchestrator — detect stage, route to the right skill

This skill is a thin router. It does not duplicate logic from the other three `nanobc-*` skills. Its job is to ask: **"what stage is the user at, and which skill should they invoke next?"**

### 0.1 Inputs / Outputs contract

**Inputs (consumed)**

| Path | Source | Required? |
| --- | --- | --- |
| `$NANOBC_HOME/main.nf` | pipeline repo (resolved in §0.2) | yes |
| `$RUN_DIR/params.json` | `nanobc-preflight` | for the `run` stage |
| `$RUN_DIR/nextflow.config.<env>.local` | `nanobc-preflight` (optional) | no |
| `$RUN_DIR/diagnosis.md` | `nanobc-debug` | for `review-diagnosis` |
| `$RUN_DIR/progress.log` | `track-progress.sh` (deployed by this skill) | no (read-back) |

**Outputs (produced)**

| Path | Owner | Format | Notes |
| --- | --- | --- | --- |
| Run command (nextflow or bash-recipe mode, §0.6a) | this skill | printed text | never executed without explicit confirmation (SP1) |
| Handoff message | this skill | printed text | names the next skill and the artifact it produces |
| `$RUN_DIR/progress.log` | `track-progress.sh` | log | produced by the helper script, not by this skill itself (nextflow mode only) |
| `$OUTDIR/logging/manual_run_<ts>.log` | `run_basecalling.sh` (bash mode) | log | per-run transcript of the manual path, consumed by `nanobc-debug` |

**Verdict gate**

This skill **refuses to execute** the pipeline — in either execution mode — unless `$RUN_DIR/params.json` exists **and** `$RUN_DIR/params.rationale.md` records an overall verdict of `GO` or `GO-WITH-WARNINGS` (written by `nanobc-preflight`, see its §4). A `NO-GO` verdict stops the pipeline — route back to `nanobc-preflight` instead of running.

### 0.2 Resolve the pipeline and run directory

Same convention as the other skills: `$NANOBC_HOME` env var, or sibling `../nf-nanopore-basecalling`.

```bash
: "${NANOBC_HOME:=$(cd "$SKILL_DIR/../../../nf-nanopore-basecalling" 2>/dev/null && pwd)}"
test -f "$NANOBC_HOME/main.nf" || { echo "Cannot locate nf-nanopore-basecalling. Set NANOBC_HOME."; exit 1; }

# Run dir is wherever the user wants params.json / reports to live.
# Recommend a dedicated dir per sample/flow cell (e.g. runs/N046), not $NANOBC_HOME itself,
# since this pipeline is typically re-run many times against different pod5 batches.
: "${RUN_DIR:=$NANOBC_HOME}"
```

### 0.3 Determine the user's stage

Try to detect automatically **before** asking:

```bash
OUTDIR=$(jq -r '.outdir // empty' < "$RUN_DIR/params.json" 2>/dev/null)

# $OUTDIR/fastq/ populated → barcode-path run finished (bam2fq publishDir)
if [ -n "$OUTDIR" ] && ls "$OUTDIR"/fastq/*.fastq.gz >/dev/null 2>&1; then
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

If auto-detection is ambiguous (e.g. `params.json` exists but no `.nextflow.log` — unclear if it ever ran), ask stop point **SP0** (§0.5):

> Are you starting a new run, or continuing a previous one?
>
> - new run (no params.json yet)
> - I have params.json already, haven't run it
> - I just ran it and it failed
> - I just ran it successfully

### 0.5 Master ask-user stop points

This skill has **four** user-facing stop points (SP0, SP1, SP1a, SP2). All other stop points live in the sub-skills (`nanobc-preflight` §0.5, `nanobc-debug`, `nanobc-qc`). The pattern is **Evidence + Recommend + Options**; if the evidence is unambiguous, the agent auto-picks the default and proceeds silently.

#### SP0 — Entry-stage ambiguity

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| Stage ladder (§0.3) returns `run` but no `.nextflow.log` exists | `params.json` present, no run history — unclear if it ever ran | "Are you starting a new run, or continuing a previous one?" with the four options from §0.3 |

**Auto-pick when**: no `params.json` and no artifacts at all → `preflight` stage, no question needed.

#### SP1 — Run confirmation

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| Stage is `run` | `params.json` exists, config override resolved (§0.6) | "This will start a Nextflow run with the params above. OK to proceed? (yes / no / dry-run)" |

**Auto-pick when**: the user already said "just run it" — skip the question but still print the exact command first. Never auto-pick `yes` otherwise.

#### SP2 — Progress-tracker frequency

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| `local`-profile run expected to take many hours | Tracker deployable (§0.6) | "How often would you like progress updates — every 2 h / 1 h / 30 min?" |

**Auto-pick when**: the user has no preference → default 7200 s (every 2 h).

#### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** When asking, present the evidence first, then the recommendation, then 2–4 concrete options. Do not ask "what do you want?" — ask "I see X, recommend Y, which one of A/B/C?"

### 0.4 Route to the right skill

| Stage              | Action                                                                                                |
| ------------------ | ------------------------------------------------------------------------------------------------------ |
| `preflight`        | Invoke `nanobc-preflight`. It produces `params.json` and the run command. Come back here when done.    |
| `run`              | Show the run command (see §0.6). Get explicit confirmation (SP1). Then run.                           |
| `debug`            | Invoke `nanobc-debug`. It writes `diagnosis.md`. Come back when done.                                  |
| `qc`               | Invoke `nanobc-qc`. It writes `report.md`.                                                             |
| `review-diagnosis` | Read `$RUN_DIR/diagnosis.md` with the user, recommend Option A from its "Recommended next action" block. |

**Do not skip preflight.** Even if the user supplies params manually, recommend running `nanobc-preflight` first — it's the only place Dorado's version and the kit/model choices get validated and recorded (Dorado has no pixi/conda pin, so this audit trail matters more here than for the pixi-managed tools).

### 0.6a The execution-mode fork (pick per run)

The pipeline wraps the same Dorado/samtools steps in two execution modes, mirrored from the skillforge-style convention (**bash recipes = single-machine default; Nextflow runner = HPC / cohort / trace reports**):

| Mode | When | Cost / requirement | Where |
| --- | --- | --- | --- |
| **Nextflow runner** (default on HPC, cohort runs) | SLURM/cluster execution, `-resume` caching, trace/report/timeline artifacts, `--transfer_dest` per-process retry semantics | Nextflow ≥ 23.04 on `$PATH` | `$NANOBC_HOME/main.nf` (§0.6) |
| **Manual bash recipes** | single workstation, one-off runs, environments where Nextflow is unavailable or overkill (e.g. a quick 1–2 pod5-chunk basecall), or debugging a single step in isolation | bash + dorado on PATH (or `--dorado_bin`); samtools comes via the pinned pixi env on the barcoded path | `$NANOBC_HOME/runners/bash-recipes/run_basecalling.sh` (§0.7) |

The two modes produce **identical output layouts** (LSK: `$OUTDIR/dorado_basecall_lsk/`; barcoded: `$OUTDIR/fastq/`), so `nanobc-qc` and `nanobc-debug` are mode-agnostic. The bash recipes are command-for-command mirrors of `modules/dorado.nf` — if one diverges, fix the pipeline first, then the recipes (same commit). The manual path has **no `-resume`**: re-running re-runs every pod5 chunk (it does not skip completed files), so for long or interruptible runs prefer the Nextflow runner.

#### SP1a — execution mode

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| Stage is `run` and `params.json` does not record `execution_mode` | no mode pinned by preflight | "This run can execute via the Nextflow runner or the manual bash recipes — which? (nextflow / manual / let me pick)" with the §0.6a table as the evidence panel |

**Auto-pick when**: (a) `params.json` already records `execution_mode` (written by `nanobc-preflight`, SP6) — honour it silently; (b) the user explicitly said "slurm/cluster/cohort" → `nextflow`; (c) the user explicitly said "without nextflow / bash / manual / quick" → `manual`; (d) neither signal and the run targets a workstation with ≤ 2 pod5 chunks and no cluster profile in play → recommend `manual`, ask only if the user hesitates. Never auto-pick `nextflow` on a machine where `nextflow` is not on `$PATH` — fall back to `manual` (and vice versa: no dorado binary → neither mode runs; stop and tell the user).

### 0.6 The nextflow-runner command (mode = `nextflow`)

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
  echo "(the shipped slurm clusterOptions are PLACEHOLDERS: <gpu_partition>/<gpu_gres> for the 'dorado' label;"
  echo " if this cluster doesn't have them, write a real override via nanobc-preflight §2.5c/d first.)"
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

### Optional pre-run: force the GPU fan to max (local profile only)

If this is a `local`-profile run on the workstation, recommend forcing the fan to 100% before a long basecall — Dorado keeps the GPU at near-100% utilization for hours, and a lower-power (Max-Q-class) cooler (see `nanobc-preflight` §2e.1/e.2 and `../gpu-host-notes.md` for this host's card) has the least headroom for exactly that load. The helper lives next to the preflight skill:

```bash
"$SKILL_DIR/gpu-fan.sh" status    # read-only snapshot
"$SKILL_DIR/gpu-fan.sh" max       # force fan to 100% (verified read-back)
```

**There is no auto-restore** — the fan stays at max until `"$SKILL_DIR/gpu-fan.sh" auto` is run. When the run finishes (handoff to `nanobc-qc`), remind the user to run `auto` to hand the curve back to firmware. Skip entirely on `slurm` profiles (you don't control the compute node's fans).

Ask (stop point **SP1**, §0.5): **"This will start a basecalling run (mode from SP1a) with the params above. OK to proceed? (yes / no / dry-run)"**

### 0.7 The manual bash-recipes command (mode = `manual`)

The manual path is one script wrapping both kit paths plus the shared demux helper, in `$NANOBC_HOME/runners/bash-recipes/`:

```bash
# LSK kit (e.g. SQK-LSK114) — emits FASTQ directly per pod5 chunk:
bash "$NANOBC_HOME/runners/bash-recipes/run_basecalling.sh" \
  --pod5 "input_folder/N046/*.pod5" \
  --model /path/to/dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
  --kitname SQK-LSK114 \
  --outdir "$OUTDIR"

# Barcoded kit (e.g. SQK-RBK114) — basecalls to BAM, then demultiplexes
# (same samtools+awk BC:Z logic as the bam2fq process, pinned pixi env):
bash "$NANOBC_HOME/runners/bash-recipes/run_basecalling.sh" \
  --pod5 "input_folder/N046/*.pod5" \
  --model /path/to/dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
  --kitname SQK-RBK114 \
  --outdir "$OUTDIR"

# Or consume the preflight params.json directly (keys = main.nf's schema):
bash "$NANOBC_HOME/runners/bash-recipes/run_basecalling.sh" \
  --params-file "$RUN_DIR/params.json"
```

Behaviour mirrors the Nextflow processes exactly:

- Validation parity with `main.nf`: missing `--pod5`/`--model` aborts early; an unmatched pod5 glob aborts (`checkIfExists: true` parity); the dorado binary must be resolvable.
- **LSK path** = `dorado_basecall_lsk`: `dorado basecaller -x cuda:all --emit-fastq MODEL POD5 | gzip`, published to `$OUTDIR/dorado_basecall_lsk/<id>.fastq.gz`, with `set -o pipefail` semantics and an explicit empty-output guard (the pipeline's #1 historical silent-failure mode).
- **Barcoded path** = `dorado_basecall` + `bam2fq`: BAM per chunk in `$OUTDIR/`, then `demux_bam.sh` (samtools via the pinned `envs/samtools` pixi env) publishes `$OUTDIR/fastq/<barcode>.fastq.gz` incl. `unknown.fastq.gz`.
- **Optional** `--transfer_dest user@host:/path` mirrors the `transfer` process (ssh mkdir + rsync), LSK only.
- `concat_fastq` / `total_bases` are intentionally absent — they are off the shipped Nextflow DAG too.
- A full transcript lands in `$OUTDIR/logging/manual_run_<timestamp>.log` — hand this file to `nanobc-debug` on failure instead of `.nextflow.log`.
- No resume: completed chunks are re-run on retry. For interruptible/long runs recommend mode `nextflow` instead.
- Hardware prerequisites are unchanged: dorado still needs a CUDA GPU and a model directory — the manual path removes Nextflow from the equation, not the GPU.

**Validate before first use** (any machine, CPU-only, no dorado needed): `bash "$NANOBC_HOME/runners/bash-recipes/test_smoke.sh"` — checks recipe syntax, awk lock-step against `modules/dorado.nf`, and functionally demultiplexes a synthetic BC:Z BAM via the pinned samtools env.

Then continue from the **Recommend preview** step below (for mode `manual` the analogue of `-preview` is the validation + the printed per-file plan), and apply SP1 confirmation as usual.

### Recommend preview for first-time users

```bash
nextflow run main.nf -profile slurm $CONFIG_FLAG -params-file "$RUN_DIR/params.json" -preview
```

`-preview` (renamed from `-dry-run` in Nextflow 25.06; the old flag errors on Nextflow ≥ 25.06) shows the planned DAG and resolved per-process `cpus`/`memory`/`clusterOptions` without submitting anything — a quick way to confirm a config override is actually being picked up, and to catch a bad `pod5` glob (via `checkIfExists: true`) before it reaches the scheduler.

### Resume is a separate, distinct command

If the user says "I already ran this, just resume", do NOT use the bare `nextflow run` command:

```bash
nextflow run main.nf -profile slurm $CONFIG_FLAG -params-file "$RUN_DIR/params.json" -resume
```

`-resume` picks up cached completed tasks from `.nextflow/` and re-runs only what failed or changed. If the user changed the override (e.g. bumped the `dorado` label's `memory` or fixed the partition/gres) between the failed and resumed run, `-resume` will retry the failed task with the new settings — always suggest it as the *first* retry after a failure.

### Optional post-launch: deploy the progress tracker (local profile, long runs)

For runs expected to take many hours, offer to deploy `$SKILL_DIR/track-progress.sh` — a background helper that writes a progress line to `$RUN_DIR/progress.log` (time, RUNNING/FINISHED status, files done of total, output size, GPU state) until the run finishes. This gives the user — and any future session asked to "check progress" — a full history even when nobody is watching the screen. Deploy right after launching the run.

**Let the USER choose the tracking frequency** (stop point **SP2**, §0.5) — ask how often they'd like updates (e.g. every 2 hours, every hour, every 30 min). Default is every 2 hours (7200 s) if they have no preference. Convert their answer to seconds: 1 hour = 3600, 30 min = 1800, 6 hours = 21600.

```bash
TMUX_SESSION="basecalling_PR001"                 # must match the tmux session name
POD5_GLOB=$(jq -r '.pod5' < "$RUN_DIR/params.json")
POD5_COUNT=$(ls $POD5_GLOB 2>/dev/null | wc -l)  # LSK path: "files done" == completed .fastq.gz vs pod5 count
OUTDIR_FASTQ="$(jq -r '.outdir' < "$RUN_DIR/params.json")/dorado_basecall_lsk"
INTERVAL=7200                                     # user's choice; 7200 = every 2 hours (default)

nohup bash "$SKILL_DIR/track-progress.sh" "$TMUX_SESSION" "$OUTDIR_FASTQ" "$POD5_COUNT" "$RUN_DIR/progress.log" "$INTERVAL" > /dev/null 2>&1 &
```

- **LSK path (no demux):** pass the `dorado_basecall_lsk` outdir and the pod5 count — the tracker counts `.fastq.gz` files and can stop early when the count is reached.
- **Demux (RBK) path:** per-barcode output lands in `${outdir}/fastq/` (one per barcode + `unknown`); pass that dir and `0` for the total — completion is signalled by the tmux session ending, not a file count.
- **Stops on its own** when the tmux session ends (run finished, success or failure) or when the file count reaches the total. No cleanup needed.
- **Frequency is the user's choice:** default is every 2 hours (7200 s); pass a 5th argument in seconds for a different interval (e.g. `3600` = every hour, `1800` = every 30 min). Always ask the user, don't assume.
- **Reading it back:** `tail -n 20 "$RUN_DIR/progress.log"` and summarize in plain English (files done, output size growth, GPU temp trend).
- **Skip on `slurm` profiles** — you don't control the compute node, and tmux session name would refer to a local session that never sees the job.

## 1. After the run

| Outcome                                        | Next skill                                        |
| ----------------------------------------------- | -------------------------------------------------- |
| Exit 0, `$OUTDIR/fastq/` populated or LSK FASTQ exists | `nanobc-qc`                                     |
| Exit non-zero, no `diagnosis.md`                 | `nanobc-debug`                                     |
| `diagnosis.md` already exists                    | walk the user through Option A from it             |
| User says "looks good" after QC                  | done — point them to `$RUN_DIR/report.md` and `$OUTDIR/` |

After invoking any next-step skill, **explicitly hand off** — don't make the user discover the next action. Example:

> I've handed off to `nanobc-qc`. It will check the output FASTQs and per-barcode read counts, then write `report.md` to your run directory. Say the word and I'll invoke it.

## 2. Important rules

- **Never** run the pipeline without explicit user confirmation
- **Never** edit `params.json` after preflight — if values are wrong, re-run `nanobc-preflight`
- **Always** recommend `-preview` for first-time users (unless they explicitly say "just run it") — on Nextflow < 25.06 the flag is spelled `-dry-run`; check `nextflow run -help`
- **Always** offer to invoke the next skill — don't leave the user to find it
- **Never** run two nextflow runs in the same `$RUN_DIR` concurrently — `-resume` cannot disambiguate them. If the user wants to start over, move `.nextflow/` aside first or use a new run directory.
- **If `$NANOBC_HOME` doesn't resolve, ask** before guessing. A wrong pipeline home = wasted GPU time.
- **Recommend a run directory per sample/flow cell** (e.g. `runs/<sample>/`), not reusing `$NANOBC_HOME` itself — this pipeline is normally re-run repeatedly against different pod5 batches, and the existing `params/example.json` (`transfer_dest: .../destination/N046/`) is itself an example of a per-sample output path.

## A. Pipeline architecture — the evidence chain

The agentic layer follows a phased evidence chain. Each phase consumes the artifacts of the previous phase and gates progression — the boundary between phases is the **filesystem**, not agent memory.

| # | Phase | Goal | Skill | Artifact produced |
|:--|:------|:-----|:------|:------------------|
| **1** | **Preflight** | Validate pod5/model/kit/GPU/cluster, write params | `nanobc-preflight` | `$RUN_DIR/params.json` + `params.rationale.md` (+ optional `nextflow.config.<env>.local`) |
| **2** | **Run** | Execute the run (mode from `params.json:execution_mode`: Nextflow runner §0.6 or manual bash recipes §0.7) | this skill | FASTQs under `$OUTDIR` (pipeline outputs, identical layouts in both modes) |
| **3** | **Debug** | Interpret a failed run | `nanobc-debug` | `$RUN_DIR/diagnosis.md` (top-3 ranked hypotheses) |
| **4** | **QC** | Check output integrity + read counts | `nanobc-qc` | `$RUN_DIR/report.md` (overall PASS / PASS-WITH-WARNINGS / FAIL) |

## B. Go/No-Go gates

The agent must stop and warn the user if:

- **Preflight `NO-GO`**: `params.rationale.md` shows a `NO-GO` verdict (e.g. GPU unusable on a `local` profile, hardcoded partitions absent with no user override) — do **not** run.
- **QC `FAIL`**: `report.md` shows overall `FAIL` — do **not** declare the run good; hand off to `nanobc-debug`.
- **Ambiguous stage**: SP0 (§0.5) fires and the user's answer is still unclear — ask before routing.

## C. Output contract — no artifact

This skill produces **no file** of its own. Its only outputs are:

- The run command (printed to the user)
- The hand-off message naming the next skill

All artifacts (`params.json`, `diagnosis.md`, `report.md`) are produced by the other three skills. Don't try to write them from here. (When the tracker is deployed, `$RUN_DIR/progress.log` is produced by `track-progress.sh`, not by this skill itself.)

## D. Common follow-ups

| User says                       | What to do                                                                                          |
| -------------------------------- | ----------------------------------------------------------------------------------------------------- |
| "Check progress" / "how's it going" | Read `$RUN_DIR/progress.log` (tracker history, if deployed) + `tmux capture-pane -t <session> -p`; summarize in plain English |
| "Looks good" after QC             | Summarize: kitname/path taken, output location, key QC verdicts                                       |
| "Can I trust this output?"        | Point them to `$RUN_DIR/report.md` and `$RUN_DIR/params.rationale.md` — both are audit-trail artifacts |
| "I want to run more samples"      | Recommend a new `$RUN_DIR` per sample; `$NANOBC_HOME` (the pipeline) can be shared across all of them |
| "How do I cite this?"             | `cat "$NANOBC_HOME/README.md"`                                                                          |

## Verification

- [ ] Stage was detected from filesystem evidence (or SP0 was asked) **before** any routing.
- [ ] `params.json` existed and `params.rationale.md` verdict was `GO` / `GO-WITH-WARNINGS` before `nextflow run` fired.
- [ ] Explicit confirmation (SP1) was obtained before every `nextflow run` (none for `-preview`).
- [ ] The next-step skill was named explicitly in a handoff message; no artifact of another skill was written by this skill.
- [ ] On a `local` run with the tracker deployed: the tracker's frequency was the user's choice (SP2), and `gpu-fan.sh auto` restore was mentioned in the handoff.

## Handoff pointers

After routing, explicitly state which skill was invoked and which file it produces — don't make the user discover the next action (see the handoff message examples in §1).

## Provenance

Part of the `nanobc` skill bundle (v1.2.0), authored following the [bioinfo-skill-creator](https://github.com/cheahhl814/bioinfo-skill-creator) meta-skill conventions (filesystem evidence chain, explicit stop points, verdict gates) and the skillforge bash-recipes/nextflow-runner dual-path convention. Sibling skills: `nanobc-preflight`, `nanobc-debug`, `nanobc-qc`.
