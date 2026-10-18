---
name: nanobc-debug
description: 'Interpret a failed nf-nanopore-basecalling Nextflow run, including CUDA/GPU errors, NVIDIA driver/library version mismatches, GPU thermal throttling, Dorado model/kit errors, pixi env issues, and SLURM partition/gres mismatches. Use when nextflow log shows ERR, exit status 1, exit 137 (OOM-kill), a Dorado/samtools/seqtk/transfer process failed, or a run is unexpectedly slow.'
version: 1.2.1
updated: "2026-10-18"
triggers:
  - "basecalling failed"
  - "dorado error"
  - "why did the pipeline fail"
  - "nextflow failure"
  - "nanobc debug"
  - "CUDA out of memory dorado"
  - "pixi command not found"
  - "unknown barcode fastq empty"
  - "rsync transfer failed"
  - "nvidia-smi driver library version mismatch"
  - "gpu overheating"
  - "dorado run slower than usual"
  - "gpu throttling"
---

# nanobc-debug — nf-nanopore-basecalling failure interpreter

> **v1.2.1.*** Reactive failure interpreter for the `nanobc-*` bundle: reads the run history + work-dir evidence (either execution mode), ranks the top-3 hypotheses, and writes `$RUN_DIR/diagnosis.md` with concrete fix options. It does **not** re-run the pipeline.

## Audience

This skill serves two purposes:

- **AI Agents**: Triggered by the phrases above. Must read the **actual** error before concluding, produce multiple ranked hypotheses, and write the `diagnosis.md` artifact.
- **Human Users**: Provides a transparent audit trail — every hypothesis is cited back to a quoted error line, never guessed from the process name alone.

## When to Use This Skill

Use this skill when:

- A `nextflow run` exited non-zero (ERR in the log, exit status 1, exit 137 OOM-kill, a Dorado/samtools/seqtk/transfer process failed)
- A run completed but is unexpectedly slow compared to a comparable prior run (possible thermal throttling, §1.6)
- Output looks wrong (e.g. empty FASTQs, almost all reads `unclassified`) and the cause is unknown

Do NOT use this skill if:

- Nothing has run yet — params need preparing → `nanobc-preflight`
- The run succeeded and the user wants output QC → `nanobc-qc`
- The user just wants to launch/resume a healthy run → `nanobc-run`
- The failure is already diagnosed in `$RUN_DIR/diagnosis.md` and the user wants to act on it → `nanobc-run` (§5, `review-diagnosis`)

## 0. Inputs / Outputs contract

### Inputs (consumed)

Evidence location depends on the **execution mode** of the failed run (`params.json:execution_mode`, §0.1):

| Path | Source | Required? | Mode |
| --- | --- | --- | --- |
| `$LAUNCH_DIR/.nextflow.log` (+ `.nextflow/` history) | previous `nextflow run` (resolved in §0.1) | yes | `nextflow` |
| Run name / session id | `$RUN_NAME` env or `nextflow log -q` (§0.1) | yes | `nextflow` |
| `$OUTDIR/logging/manual_run_<ts>.log` | `run_basecalling.sh` transcript (§0.1) | yes | `manual` |
| `$RUN_DIR/params.json` | `nanobc-preflight` | yes (kit/model/outdir context) | both |
| `$RUN_DIR/nextflow.config.<env>.local` | `nanobc-preflight` (optional) | no — tells whether an override was in force | `nextflow` |
| `$WORKDIR/.command.err` / `.log` / `.command.sh` / `.exitcode` | Nextflow task work dirs (§1) | yes, per failing task | `nextflow` |
| `nvidia-smi` on the compute node | node (§1.5/§1.6) | no (best-effort; may itself be broken) | both |

### Outputs (produced)

| Path | Owner | Format | Notes |
| --- | --- | --- | --- |
| `$RUN_DIR/diagnosis.md` | this skill | Markdown | failed processes + top-3 ranked hypotheses + Option A/B fixes |
| Signature-library row additions | this skill | edit to §2 tables | every genuinely new error pattern gets a row |

### Verdict gate

`nanobc-run` **refuses to route to `nanobc-qc`** until a re-run exits 0 — a `diagnosis.md` without a **"Recommended next action"** block (§3) is incomplete and must be regenerated. Conversely, never re-run the pipeline (either execution mode) without the user having picked one of the fix options from `diagnosis.md` (SP1, §0.5).

### 0.1 Locate the pipeline, the launch dir, and the run

```bash
: "${NANOBC_HOME:=$(cd "$SKILL_DIR/../../../nf-nanopore-basecalling" 2>/dev/null && pwd)}"
test -f "$NANOBC_HOME/main.nf" || { echo "Cannot locate nf-nanopore-basecalling. Set NANOBC_HOME."; exit 1; }

# Execution mode of the failed run — decides WHERE the evidence lives.
MODE=$(jq -r '.execution_mode // "nextflow"' < "$RUN_DIR/params.json" 2>/dev/null)
```

**Mode = `manual`** — there is no `.nextflow.log` and no work-dir tree. The evidence is the recipe transcript plus the output tree:

```bash
# the recipe writes one log per invocation under $OUTDIR/logging/
LOG=$(ls -t "$OUTDIR"/logging/manual_run_*.log 2>/dev/null | head -1)
test -n "$LOG" || { echo "No manual_run_*.log found under "$OUTDIR"/logging — the recipe may never have started"; exit 1; }
# dorado stderr is appended to the same log (the recipe redirects 2>>"$LOGFILE");
# read it tail-first — the failure is almost always at the bottom.
tail -n 50 "$LOG"
# per-process state in the output tree mirrors the pipeline's publishDir layout:
#   LSK:        $OUTDIR/dorado_basecall_lsk/<id>.fastq.gz
#   barcoded:   $OUTDIR/<id>.bam + $OUTDIR/fastq/<barcode>.fastq.gz
ls -la "$OUTDIR" "$OUTDIR"/fastq 2>/dev/null
```

There is no manual-path analogue of `-resume` (every pod5 chunk re-runs); a diagnosis fix therefore means re-running `run_basecalling.sh` whole — factor that into the fix options (e.g. test on one chunk first via a narrowed `--pod5` glob).

**Mode = `nextflow`** — proceed as below:

```bash
# RUN_DIR = wherever params.json / reports live (nanobc-run may use a dedicated per-sample dir).
# LAUNCH_DIR = the directory nextflow was launched from. Its `.nextflow/` + `.nextflow.log`
#   hold the run history that `nextflow log` reads — usually $NANOBC_HOME, NOT the artifacts
#   RUN_DIR. If the run was launched from the RUN_DIR itself, set LAUNCH_DIR="$RUN_DIR".
: "${RUN_DIR:=$NANOBC_HOME}"
: "${LAUNCH_DIR:=$NANOBC_HOME}"
test -f "$LAUNCH_DIR/.nextflow.log" || { echo "No .nextflow.log found in $LAUNCH_DIR (the nextflow launch dir)"; exit 1; }

# `nextflow log` takes a run NAME / session id — NOT a directory path — and reads the
# history from the current working directory. Resolve a run name here (pass RUN_NAME in,
# or default to the most recent run in LAUNCH_DIR).
RUN_NAME="${RUN_NAME:-$(cd "$LAUNCH_DIR" && nextflow log -q | tail -1)}"
test -n "$RUN_NAME" || { echo "No runs found via 'nextflow log -q' in $LAUNCH_DIR"; exit 1; }
```

### 0.5 Ask-User Stop Points

This sub-skill has **three** stop points (SP1–SP3). Each fires only when the evidence is ambiguous; the format is **Evidence + Recommend + Options**.

#### SP1 — Permission to modify pipeline code

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| A top hypothesis points to a genuine script defect (e.g. the historical missing-`pipefail` in `modules/dorado.nf`, §2 Dorado table) rather than params/config | Hypothesis confidence + quoted `.command.err` | "Patch `main.nf`/`modules/dorado.nf`, or route around it (different kit/model/override) instead?" |

**Auto-pick when**: never — do **not** modify `main.nf`/`modules/` without the user's explicit go-ahead (§4).

#### SP2 — Node-level fix vs admin report

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| Driver/library version mismatch on the GPU node (§1.6) | `nvidia-smi` NVML failure | "Reboot/reload here (do you have sudo and is anything else using the GPU?), or report to the cluster admin?" |

**Auto-pick when**: it's the local workstation and the user has sudo and nothing else is using the GPU → suggest the reload command without a stop. On a shared SLURM node → always report to admins, no stop needed.

#### SP3 — Which fix option to execute

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| `diagnosis.md` written and the user is ready to act | Top-3 hypotheses ranked with confidence | "Evidence points to `<top hypothesis>` — recommend Option A. Try A first, or B?" |

**Auto-pick when**: one hypothesis is clearly high-confidence while the rest are low → state "proceeding with Option A" and proceed (the user can still veto).

#### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** When asking, present the evidence first, then the recommendation, then 2–4 concrete options. Do not ask "what do you want?" — ask "I see X, recommend Y, which one of A/B/C?"

## 1. Identify the failing process(es)

```bash
cd "$LAUNCH_DIR"
nextflow log -f "process,name,status,exit,hash,duration" "$RUN_NAME" \
  | awk -F'\t' '$3 != "COMPLETED" { print }'
```

For each failure, get the work directory and read the raw evidence:

```bash
cd "$LAUNCH_DIR"
nextflow log -f "process,name,exit,hash,workdir" "$RUN_NAME" | grep -F "$HASH"
```

- `$WORKDIR/.command.err` — actual stderr
- `$WORKDIR/.command.log` — full stdout
- `$WORKDIR/.command.sh` — the exact command run (useful to reproduce interactively)
- `$WORKDIR/.exitcode`

## 1.5 OOM / GPU diagnosis: config vs. reality

Before the signature library, rule out the mechanical config-vs-machine mismatches — these are the highest-frequency failures in this pipeline because Dorado needs a GPU and the shipped SLURM partition/gres values are per-cluster placeholders (see `nanobc-preflight` §2.5):

```bash
HASH=<failing hash>
cd "$LAUNCH_DIR"
nextflow log -f "process,name,cpus,memory,realtime,hash" "$RUN_NAME" | grep -F "$HASH"

# Was a user-side config override applied?
USER_CONFIG="$RUN_DIR/nextflow.config.${NANOBC_PROFILE:-slurm}.local"
[ -f "$USER_CONFIG" ] && echo "User override in use: $USER_CONFIG" \
                      || echo "No user override — using $NANOBC_HOME/nextflow.config defaults (PLACEHOLDER partition/gres for the 'dorado' label — write a real override via nanobc-preflight §2.5c/d)"
```

- **Job never starts / stuck `PD` in `squeue`** with reason `Invalid Gres` / `PartitionConfig` / `ReqNodeNotAvail` → the (placeholder) `--gres`/`--partition` in the shipped config — or a stale override — doesn't exist on this cluster. Fix: `nanobc-preflight` §2.5c/d to write a `nextflow.config.slurm.local` override with real partition/gres names, applied via `-c`. **Do not** edit `nextflow.config` directly.
- **Exit 137 (SIGKILL)** on the `dorado` label → almost always an OOM-kill, either host RAM (40 GB requested) or **GPU** memory (CUDA OOM — see below). Check both before concluding.
- **CUDA error inside `.command.err`** (not a SLURM scheduling issue) → see the Dorado table below.

## 1.6 Driver/library mismatch and thermal throttling

Two GPU-health failure modes that look nothing like a normal Dorado error and are easy to misdiagnose as a pipeline/config bug:

### Driver/library version mismatch

```bash
nvidia-smi 2>&1 | head -3
# "Failed to initialize NVML: Driver/library version mismatch" is the tell
```

This means the installed userspace driver package is newer (or older) than the kernel module currently loaded — typically because a driver update was installed but the machine/node hasn't rebooted (or the module hasn't been reloaded) since. It affects **every** GPU job on that node, not just this run — if this shows up, don't spend time on Dorado-specific hypotheses first.

```bash
cat /proc/driver/nvidia/version 2>/dev/null | head -1   # loaded kernel module version
dpkg -l 2>/dev/null | awk '/nvidia-driver-[0-9]+/ {print $2, $3}'   # installed package version
```

Fix: reboot the node, or (if nothing else is using the GPU) `sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia && sudo modprobe nvidia`. On a shared SLURM node you may not have permission to do this yourself — report it to the cluster admin rather than working around it in the pipeline.

### Thermal throttling mid-run

A run that completes successfully but takes noticeably longer than a comparable prior run (same model, similar pod5 volume) — with no error in `.command.err` — is a signature of throttling, not a bug:

```bash
# If you have shell access to the node while the job is running (or can log this proactively
# for next time — see "extending" note below). temperature.gpu and clocks.sm/clocks.max.sm are
# near-universally supported; clocks_throttle_reasons.* varies by GPU/driver — query it
# separately and don't let an unsupported field block reading the rest:
nvidia-smi --query-gpu=temperature.gpu,clocks.sm,clocks.max.sm --format=csv,noheader
nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv,noheader 2>&1 \
  || echo "clocks_throttle_reasons.active not supported here — fall back to temp + clocks.sm vs clocks.max.sm gap as the throttling signal"
```

**Not yet verified against real hardware.** These exact `nvidia-smi` field names come from documented NVML query fields, not from a run that's actually succeeded on this repo's own workstation — `nvidia-smi` has been stuck in the driver/library-mismatch state (§1.6) the entire time these skills were written. Treat the field list as a starting point to confirm with `nvidia-smi --help-query-gpu` (once the mismatch is fixed) rather than as a guaranteed-working command.

| Observation | Likely cause | Suggested fix |
|---|---|---|
| `clocks_throttle_reasons.active` shows `SW Thermal Slowdown` / `HW Slowdown`, `clocks.sm` well below `clocks.max.sm` | GPU is thermally throttling under sustained Dorado load | Confirm with `"$SKILL_DIR/gpu-fan.sh" status` (fan RPM/target) on the node if accessible; check chassis airflow/dust/fan health physically; on a shared cluster node, report to admins — this isn't fixable from the pipeline side |
| Temperature climbs steadily across the run and plateaus near the card's throttle point | Cooling is marginal for sustained 100% GPU utilization (basecalling is a long, steady load, unlike bursty graphics workloads) | Same as above; consider running on a different node/partition if this recurs |
| No throttle reasons active, temp stable, but runtime still longer than expected | Not a thermal issue — check `nanobc-preflight`'s "do not fabricate a throughput number" note; compare against your own prior runs, not an assumed baseline | — |

Nextflow's own trace (`cd "$LAUNCH_DIR" && nextflow log -f "process,name,realtime,hash" "$RUN_NAME"`) gives you the actual wall-clock duration to compare against prior runs of the same process — use that as your "slower than expected" baseline, not a guessed number.

**Weight throttling by the host card's cooling class** (recorded in `../gpu-host-notes.md` — see `nanobc-preflight` §2e.1): lower-power variants (Max-Q class) trade cooling headroom for lower power/noise, and Dorado's long, steady, near-100%-utilization load is exactly what their cooling isn't validated against — weight the throttling hypothesis higher there. On full-power cards, weight it lower and check the driver-mismatch and config-mismatch hypotheses first.

**This pipeline has no automated fan control** (and generally can't — fan curves are managed by the GPU firmware/driver, not something a Nextflow process can reach into) and **no continuous temperature logging** — `nanobc-preflight`'s temperature check is a one-time snapshot before the run starts. On a workstation you *can* pre-empt this manually with `nanobc-preflight`'s `gpu-fan.sh max` before a run (fans stay at max until `gpu-fan.sh auto` — no auto-restore). If throttling turns out to be a recurring problem, the durable fix is external to this repo (better cooling, a different node, or a cron-style `nvidia-smi --query-gpu=... --format=csv -l 60 >> gpu_temp.log` left running alongside the job) — not something to bolt onto the pipeline's Nextflow processes themselves.

## 2. Signature library (extend as you encounter new failures)

Always read the actual error before concluding — never pattern-match blindly.

### Dorado (`dorado_basecall_lsk`, `dorado_basecall`)

| Signature in `.command.err` | Likely cause | Suggested fix |
|---|---|---|
| `CUDA error: out of memory` / `CUDA_ERROR_OUT_OF_MEMORY` | GPU VRAM too small for the model + batch size (common on a shared/MIG slice like `3g.39gb`) | Try a smaller/faster model variant (e.g. `fast` or `hac` instead of `sup`), or request a larger (non-MIG) GPU partition |
| `no CUDA-capable device is detected` / `CUDA driver version is insufficient` | GPU not visible in the job's cgroup, or `--gres` wasn't actually granted, or driver/CUDA mismatch on this node | Confirm with `nvidia-smi` *inside* an interactive job on the same partition; check `--gres=gpu:...` matches what SLURM actually scheduled (`scontrol show job <id>`) |
| `Failed to load model` / `No such file or directory` referencing the model path | `--model` path wrong, relative path resolved from wrong cwd, or model not downloaded | Re-check `params.model` is an absolute path that exists; re-run `nanobc-preflight` §2c |
| `dorado_basecall_lsk` **COMPLETED** (exit 0) but the fastq.gz is empty/tiny, with the real error only in `.command.err` | Run produced by a **pre-pipefail** build of `modules/dorado.nf` — the `dorado | gzip` pipe masked dorado's non-zero exit (verified bug, fixed 2026-08-03 by adding `set -o pipefail` to the process script) | `gzip -t` + read count via `nanobc-qc`; re-run with the current `dorado.nf` (it will now FAIL loudly instead of silently succeeding) |
| `Unknown kit` / `Kit ... not recognized` / kit-name parse error | `--kitname` (`params.kitname`) typo'd or not a real ONT kit code | Re-check spelling against the sequencing run's actual kit; re-run `nanobc-preflight` §2d |
| Command hangs with no GPU utilization (check `nvidia-smi` on the node) | GPU allocated but Dorado defaulting to CPU fallback, or `-x cuda:all` failed silently to find a device | Check `.command.log` for a fallback warning; confirm driver/toolkit versions match what Dorado's release expects |
| `dorado: command not found` in `.command.err` | `params.dorado_bin` not resolvable from the compute node (different `$PATH` than the login/submission node) | Use an absolute `--dorado_bin` path shared across all nodes (e.g. on shared storage), not a bare name relying on `$PATH` |
| `Failed to initialize NVML: Driver/library version mismatch` (from a `nvidia-smi` call, or Dorado itself fails to see the GPU with no clearer message) | Kernel module out of sync with installed userspace driver package on this node — see §1.6 | Reboot the node (or `modprobe` reload if nothing else is using the GPU); this is a node-level fix, not a pipeline/params fix |
| Job completes but takes much longer than a comparable prior run, no error in `.command.err` | Possible thermal throttling — see §1.6 | Check `nvidia-smi --query-gpu=temperature.gpu,clocks_throttle_reasons.active` on the node if still accessible; compare wall-clock via `nextflow log` against prior runs |
| Exit 137, GPU memory looked fine | Host RAM exceeded (SLURM `memory = '40 GB'` on `nextflow.config`) | Bump `memory` for the `dorado` label in a `nextflow.config.<env>.local` override (`withLabel:`, not `withName:`) |

### samtools / seqtk (pixi-managed: `bam2fq`)

(The `total_bases` process remains defined in `modules/dorado.nf` but is not on
the shipped DAG. `concat_fastq` was re-added to the DAG in pipeline v0.1.1 —
it aggregates per-barcode fastqs across chunks and owns the files in
`$OUTDIR/fastq`.)

### Multi-chunk outputs (pipeline v0.1.1 / recipes v1.1.0)

Historical signatures — pre-fix runs only. If these appear against a v0.1.1+
pipeline, they are a real new bug, not the known one.

| Signature | Likely cause | Suggested fix |
|---|---|---|
| Only the LAST chunk's fastq exists in `$OUTDIR`/`dorado_basecall_lsk`, named e.g. `N046.pod5.fastq.gz`; earlier chunks recoverable only from `work/` | Pre-v0.1.1 id bug: `Path.baseName` strips only the final extension, so chunk-split deliveries (`N046.pod5.001`…) all mapped to id `N046.pod5` and every chunk published the same name (`publishDir mode: 'copy'` overwrote) | Pull pipeline ≥ v0.1.1 (`pod5Id()`); re-publish recovered files from work/ or re-run |
| `concat_fastq` fails: `input file name collision — multiple input files for ... barcodeNN.fastq.gz` with a PRE-v0.1.1 pipeline copy, or any pipeline whose bam2fq outputs lack the `<id>_` prefix | Per-chunk demux outputs shared a name; staging multiple same-named files into one concat task is impossible | Pull pipeline ≥ v0.1.1 (bam2fq prefixes chunk id; main.nf parses the barcode back) |
| `$OUTDIR/fastq/barcodeNN.fastq.gz` read count << expected (fewer reads than the BAMs contain) | Pre-v0.1.1 barcoded path: each chunk's bam2fq published the same barcode file name to the same dir — later chunks silently overwrote earlier ones (data loss, same bug class as the LSK row above) | Pull pipeline ≥ v0.1.1 (`concat_fastq` aggregation); recover earlier chunks' reads from work/ if still present |
| `pod5 id collision: 'X' and 'Y' both map to id 'Z'` at launch (pipeline v0.1.1+ / recipes v1.1.0+) | Two distinct pod5 files map to the same chunk id (e.g. `a.001.pod5` and `a.pod5.001` in the same glob) | Intentional guard, not an error: rename the chunks so the distinguishing part sits before `.pod5` |

| Signature | Likely cause | Suggested fix |
|---|---|---|
| `pixi: command not found` | `pixi` isn't installed / on `$PATH` on the compute node that ran the job (common on SLURM worker nodes with a different environment than the login node) | Install pixi on all worker nodes, or point `PATH` at a shared pixi install; this is a per-cluster prerequisite the pipeline assumes silently |
| `error: no environment found` / lock mismatch from `pixi run` | `envs/<tool>/pixi.lock` out of sync with `pixi.toml`, or `.pixi/` not yet installed on this node | `pixi install --manifest-path $NANOBC_HOME/envs/<tool>/pixi.toml` once on that node (or ensure `envs/` including `.pixi/` is on shared storage) |
| `samtools: command not found` (inside the pixi run) | Broken/partial pixi env install | Re-run `pixi install --manifest-path $NANOBC_HOME/envs/samtools/pixi.toml --force-reinstall` |
| `awk: ... unexpected` in `bam2fq` | BAM has no `BC:Z:` tags at all (e.g. this BAM came from an LSK-style basecall accidentally routed through the barcode branch) | Confirm `--kitname` truly is a barcoded kit; check `samtools view <bam> | head -1` for a `BC:Z:` field |
| Almost all reads end up in `unknown.fastq.gz`, few/none in real barcode files | Reads genuinely weren't demultiplexed (kit/model mismatch, or basecalling ran without a barcoding-capable kit setting), not a script bug | Re-check `--kitname` and the Dorado invocation in `dorado_basecall` (`modules/dorado.nf:63-65`); this is a Dorado-level demux outcome, not something `bam2fq`'s awk script can fix |

### Manual execution path (`run_basecalling.sh` / `demux_bam.sh`, mode = `manual`)

Added v1.2.1. Evidence source: `$OUTDIR/logging/manual_run_<ts>.log` (the recipe appends dorado stderr here) — not `.command.err`.

| Signature in the recipe log / stderr | Likely cause | Suggested fix |
|---|---|---|
| `dorado binary '...' not resolvable` (script exits 1) | Dorado not on `$PATH` on this machine, or `--dorado_bin` wrong | Same as the nextflow-mode row — pass `--dorado_bin <abs path>` explicitly; the recipe's check is stricter than Nextflow's (it fails before basecalling, not per-task) |
| `pod5 glob matches nothing: ...` (script exits 1) | Glob wrong, run from wrong cwd, or chunks moved | Fix the glob with absolute paths (params.json parity: preflight always writes absolute paths) |
| `awk: cannot open "fastq_out/..." for output (No such file or directory)` | Demux ran with a cwd where `fastq_out/` doesn't exist — fixed in recipes v1.0.1 (scratch subshell mirrors bam2fq's work-dir semantics); older copies of `demux_bam.sh` hit this | Update `demux_bam.sh`; historical logs showing this are explained by the old version, not by the BAM |
| `gzip: fastq_out/*.fastq: No such file or directory` (right after the awk error above) | Same root cause as the awk row — awk wrote nothing, so the glob is empty | Same — fix the demux cwd/scratch, never the awk itself |
| `output ... is EMPTY — dorado likely produced nothing` (script exits via die) | Same empty-fastq failure mode as nextflow's masked-pipefail row (§2 Dorado table) — the recipe's guard catches it explicitly where the old pipeline silently succeeded | Read the dorado stderr tail in the recipe log; check the GPU rows above |
| `demux_bam.sh` exit 2 with `check BC:Z tags` hint | samtools or awk failed inside the demux subshell — usually an LSK-style BAM routed through the barcoded path | Confirm `--kitname` matches the basecall actually performed; `samtools view <bam> | head -1` for a `BC:Z:` field |
| `WARN the lock file is up-to-date but uses an older format (v6)` from pixi | Purely informational pixi format notice | Not an error — do not list it as a failure cause |

### transfer (rsync/ssh, LSK path only)

| Signature | Likely cause | Suggested fix |
|---|---|---|
| `Permission denied (publickey)` | Passwordless SSH not set up from the compute/local node to `transfer_dest`'s host | Set up an SSH key accepted by the destination host for whichever user/node runs `transfer` (it's forced to `executor 'local'`, so it always runs on the Nextflow head node, not a SLURM worker) |
| `rsync: connection unexpectedly closed` / timeout | Destination host unreachable, wrong host/path in `--transfer_dest`, or a firewall | Test manually: `ssh <user>@<host> true` and `rsync --dry-run ...` before re-running |
| Retries exhausted (3x, per `errorStrategy 'retry'` / `maxRetries 3` on `transfer`) | Persistent (not transient) failure — the retry already absorbed transient blips | Fix the underlying connectivity/permission issue; `-resume` after fixing, don't just retry again |

### Resource / scheduler

| Signature in `nextflow.log` / `squeue` | Likely cause | Suggested fix |
|---|---|---|
| `Invalid Gres specification` | the `--gres=...` profile (placeholder in the shipped config, or a stale override) doesn't exist on this cluster's GPU nodes | `nanobc-preflight` §2.5c/d — check `sinfo -o "%P %G"`, write an override |
| `Invalid partition name specified` | the placeholder/stale partition in the config or override doesn't exist here | Same as above |
| Exit status 137 | SIGKILL = OOM (host RAM or, for `dorado`, possibly GPU memory) | See §1.5 |
| Exit status 143 | SIGTERM = timeout, preemption, or manual cancel | `nextflow run -resume` |

## Interpretation Guidelines

**Confidence labels** (used on every ranked hypothesis in `diagnosis.md`):

- **high confidence** — a §2 signature-library row matches a quoted line from `.command.err` / `nextflow.log` verbatim.
- **medium confidence** — the signature matches partially, or the evidence is indirect (e.g. runtime long but no throttle-reason read-back was captured).
- **low** — plausible-by-elimination only; say what evidence would confirm or kill it.

**Verdict classes for the re-run** (also stated in `diagnosis.md`, see §5):

- **Deterministic** failure (wrong kit/model path, missing file, wrong partition name) → fix the cause, then `nextflow run -resume`.
- **Stochastic** failure (transient network blip on `transfer`, scheduler hiccup) → `-resume` is often enough on its own.
- **Upstream** failure (`dorado_basecall` produced a BAM with no real barcodes) → `-resume` won't help downstream tasks; fix basecalling params and re-run from scratch.

## 3. Output contract — write `diagnosis.md`

Always write to `$RUN_DIR/diagnosis.md`:

```markdown
# nf-nanopore-basecalling failure diagnosis

Run:      <run name from `nextflow log -q`>
When:     <ISO8601>
Profile:  slurm|local
Pipeline: $NANOBC_HOME

## Failed processes (in order of execution)

### 1. PROCESS_NAME (exit N)
- **Work dir**: $WORKDIR
- **Error excerpt**:
  \`\`\`
  <3-10 lines from .command.err>
  \`\`\`
- **Likely cause** (ranked, with confidence):
  1. **<hypothesis>** — <one-line explanation>. *(high confidence — matches '...' in skill library)*
  2. **<hypothesis>** — <one-line explanation>. *(medium)*
  3. **<hypothesis>** — <one-line explanation>. *(low)*

## Recommended next action (pick one)

### Option A — cheapest fix, try first
\`\`\`bash
<exact command the user can paste>
\`\`\`

### Option B — if A didn't help
\`\`\`bash
<exact command>
\`\`\`

## Diagnostic artifacts to inspect manually
- $WORKDIR/.command.err
- $WORKDIR/.command.log
- $WORKDIR/.command.sh
- $RUN_DIR/.nextflow.log

## Skill library extension
- If you saw a *new* error pattern, add it to the table in
  `nanobc-debug/SKILL.md` so future runs are diagnosed faster.
```

Always produce **multiple ranked hypotheses** (top 3) — use the confidence labels explicitly, and quote the actual error line rather than guessing from the process name alone.

## 4. What NOT to do

- Do **not** modify `main.nf` or `modules/dorado.nf` without the user's explicit go-ahead
- Do **not** blanket-edit `$NANOBC_HOME/nextflow.config` to "try a bigger partition" — diagnose first (§1.5), then write a `nextflow.config.<env>.local` override
- Do **not** use `withName:` in an override — this pipeline's processes carry `label` directives (`dorado`, `samtools`, `seqtk`, `transfer`); use `withLabel:`
- Do **not** assume a CUDA OOM is a host-RAM OOM (or vice versa) — check both `nvidia-smi`-reported GPU memory and the SLURM/host memory limit before recommending a fix
- Do **not** claim the `bam2fq` awk script is buggy just because most reads land in `unknown.fastq.gz` — that's very likely a genuine Dorado-level demultiplexing outcome (wrong kit/model), not a script defect

## Verification

- [ ] `$RUN_DIR/diagnosis.md` exists with: failed-process list (in execution order), top-3 ranked hypotheses **with confidence labels**, and a **Recommended next action** block with concrete Option A/B commands.
- [ ] Every hypothesis quotes actual `.command.err` / `nextflow.log` lines, not just the process name.
- [ ] The resume class (deterministic / stochastic / upstream, §5) is stated in `diagnosis.md`.
- [ ] No edits were made to `main.nf` / `modules/*.nf` without the user's explicit go-ahead (SP1).
- [ ] Any genuinely new error pattern seen this run was added as a row to the §2 signature tables.
- [ ] Config overrides, if recommended, target a `nextflow.config.<env>.local` file via `-c` with `withLabel:` blocks — `nextflow.config` itself untouched.

## 5. Resume vs re-run

- **Deterministic** failure (wrong kit/model path, missing file, wrong partition name) → fix the cause, then `nextflow run -resume` (picks up cached completed tasks).
- **Stochastic** failure (transient network blip on `transfer`, scheduler hiccup) → `-resume` is often enough on its own.
- **Upstream** failure (`dorado_basecall` produced a BAM with no real barcodes) → `-resume` won't help downstream `bam2fq`/`concat_fastq`; fix the basecalling parameters and re-run from scratch.

State which case applies in `diagnosis.md`.

## Handoff

After writing `$RUN_DIR/diagnosis.md`:

- Present Option A from the "Recommended next action" block to the user (SP3).
- **If the fix is applied and a re-run is wanted** → hand off to `nanobc-run` (`-resume` per §5); it routes to `nanobc-qc` once the run exits 0 (Verdict gate, §0).
- **If the fix fails** → return to this skill with the new error, and extend the §2 signature library if it's a new pattern.

The recommended handoff message:

> nanobc-debug complete. Wrote `$RUN_DIR/diagnosis.md` — top hypothesis: `<one-liner>` (high confidence). Recommended next action: Option A (below). Say the word and I'll execute it, then re-run via `nanobc-run` with `-resume`.
