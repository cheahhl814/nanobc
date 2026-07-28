---
name: nanobc-debug
description: Interpret a failed nf-nanopore-basecalling Nextflow run, including CUDA/GPU errors, NVIDIA driver/library version mismatches, GPU thermal throttling, Dorado model/kit errors, pixi env issues, and SLURM partition/gres mismatches. Use when nextflow log shows ERR, exit status 1, exit 137 (OOM-kill), a Dorado/samtools/seqtk/transfer process failed, or a run is unexpectedly slow. Triggers: "basecalling failed", "dorado error", "why did the pipeline fail", "nextflow failure", "nanobc debug", "CUDA out of memory dorado", "pixi command not found", "unknown barcode fastq empty", "rsync transfer failed", "nvidia-smi driver library version mismatch", "gpu overheating", "dorado run slower than usual", "gpu throttling".
---

# nanobc-debug — nf-nanopore-basecalling failure interpreter

This skill is **reactive** — invoked after a `nextflow run` has produced an error. It does not run the pipeline.

## 0. Locate the pipeline and the run

```bash
: "${NANOBC_HOME:=$(cd "$SKILL_DIR/../../../nf-nanopore-basecalling" 2>/dev/null && pwd)}"
test -f "$NANOBC_HOME/main.nf" || { echo "Cannot locate nf-nanopore-basecalling. Set NANOBC_HOME."; exit 1; }

# Run dir is wherever the user launched nextflow
RUN_DIR="${RUN_DIR:-$NANOBC_HOME}"
test -f "$RUN_DIR/.nextflow.log" || { echo "No .nextflow.log found in $RUN_DIR"; exit 1; }
```

## 1. Identify the failing process(es)

```bash
nextflow log -f "process,name,status,exit,hash,duration" "$RUN_DIR" \
  | awk -F'\t' '$3 != "COMPLETED" { print }'
```

For each failure, get the work directory and read the raw evidence:

```bash
nextflow log -f "process,name,exit,hash,workdir" "$RUN_DIR" | grep -F "$HASH"
```

- `$WORKDIR/.command.err` — actual stderr
- `$WORKDIR/.command.log` — full stdout
- `$WORKDIR/.command.sh` — the exact command run (useful to reproduce interactively)
- `$WORKDIR/.exitcode`

## 1.5 OOM / GPU diagnosis: config vs. reality

Before the signature library, rule out the mechanical config-vs-machine mismatches — these are the highest-frequency failures in this pipeline because Dorado's GPU line and the SLURM partition/gres are hardcoded per-cluster values (see `nanobc-preflight` §2.5):

```bash
HASH=<failing hash>
nextflow log -f "process,name,cpus,memory,realtime,hash" "$RUN_DIR" | grep -F "$HASH"

# Was a user-side config override applied?
USER_CONFIG="$RUN_DIR/nextflow.config.${BETA_PROFILE:-slurm}.local"
[ -f "$USER_CONFIG" ] && echo "User override in use: $USER_CONFIG" \
                      || echo "No user override — using $NANOBC_HOME/nextflow.config defaults (partition=highprio, gres=gpu:3g.39gb:1 for the 'dorado' label)"
```

- **Job never starts / stuck `PD` in `squeue`** with reason `Invalid Gres` / `PartitionConfig` / `ReqNodeNotAvail` → the `--gres=gpu:3g.39gb:1` MIG slice or `--partition=highprio` doesn't exist on this cluster. Fix: `nanobc-preflight` §2.5c/d to write a `nextflow.config.slurm.local` override with real partition/gres names, applied via `-c`. **Do not** edit `nextflow.config` directly.
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
# for next time — see "extending" note below):
nvidia-smi --query-gpu=temperature.gpu,clocks_throttle_reasons.active,clocks.sm,clocks.max.sm --format=csv,noheader
```

| Observation | Likely cause | Suggested fix |
|---|---|---|
| `clocks_throttle_reasons.active` shows `SW Thermal Slowdown` / `HW Slowdown`, `clocks.sm` well below `clocks.max.sm` | GPU is thermally throttling under sustained Dorado load | Check chassis airflow/dust/fan health physically; on a shared cluster node, report to admins — this isn't fixable from the pipeline side |
| Temperature climbs steadily across the run and plateaus near the card's throttle point | Cooling is marginal for sustained 100% GPU utilization (basecalling is a long, steady load, unlike bursty graphics workloads) | Same as above; consider running on a different node/partition if this recurs |
| No throttle reasons active, temp stable, but runtime still longer than expected | Not a thermal issue — check `nanobc-preflight`'s "do not fabricate a throughput number" note; compare against your own prior runs, not an assumed baseline | — |

Nextflow's own trace (`nextflow log -f "process,name,realtime,hash" "$RUN_DIR"`) gives you the actual wall-clock duration to compare against prior runs of the same process — use that as your "slower than expected" baseline, not a guessed number.

**On this Threadripper PRO 7975WX workstation** (local GPU: NVIDIA RTX PRO 6000 Blackwell Max-Q, 96 GB, 300 W TDP — see `nanobc-preflight` §2e.1): throttling here is more plausible than on a full-power RTX PRO 6000, since "Max-Q" trades cooling headroom for lower power/noise and isn't validated against Dorado's kind of long, steady, near-100%-utilization load the way it is against bursty graphics workloads. Weight the throttling hypothesis higher than usual on this specific host; on a different, non-Max-Q card, weight it lower and check the driver-mismatch and config-mismatch hypotheses first.

**This pipeline has no automated fan control** (and generally can't — fan curves are managed by the GPU firmware/driver, not something a Nextflow process can reach into) and **no continuous temperature logging** — `nanobc-preflight`'s temperature check is a one-time snapshot before the run starts. If throttling turns out to be a recurring problem, the durable fix is external to this repo (better cooling, a different node, or a cron-style `nvidia-smi --query-gpu=... --format=csv -l 60 >> gpu_temp.log` left running alongside the job) — not something to bolt onto the pipeline's Nextflow processes themselves.

## 2. Signature library (extend as you encounter new failures)

Always read the actual error before concluding — never pattern-match blindly.

### Dorado (`dorado_basecall_lsk`, `dorado_basecall`)

| Signature in `.command.err` | Likely cause | Suggested fix |
|---|---|---|
| `CUDA error: out of memory` / `CUDA_ERROR_OUT_OF_MEMORY` | GPU VRAM too small for the model + batch size (common on a shared/MIG slice like `3g.39gb`) | Try a smaller/faster model variant (e.g. `fast` or `hac` instead of `sup`), or request a larger (non-MIG) GPU partition |
| `no CUDA-capable device is detected` / `CUDA driver version is insufficient` | GPU not visible in the job's cgroup, or `--gres` wasn't actually granted, or driver/CUDA mismatch on this node | Confirm with `nvidia-smi` *inside* an interactive job on the same partition; check `--gres=gpu:...` matches what SLURM actually scheduled (`scontrol show job <id>`) |
| `Failed to load model` / `No such file or directory` referencing the model path | `--model` path wrong, relative path resolved from wrong cwd, or model not downloaded | Re-check `params.model` is an absolute path that exists; re-run `nanobc-preflight` §2c |
| `Unknown kit` / `Kit ... not recognized` / kit-name parse error | `--kitname` (`params.kitname`) typo'd or not a real ONT kit code | Re-check spelling against the sequencing run's actual kit; re-run `nanobc-preflight` §2d |
| Command hangs with no GPU utilization (check `nvidia-smi` on the node) | GPU allocated but Dorado defaulting to CPU fallback, or `-x cuda:all` failed silently to find a device | Check `.command.log` for a fallback warning; confirm driver/toolkit versions match what Dorado's release expects |
| `dorado: command not found` in `.command.err` | `params.dorado_bin` not resolvable from the compute node (different `$PATH` than the login/submission node) | Use an absolute `--dorado_bin` path shared across all nodes (e.g. on shared storage), not a bare name relying on `$PATH` |
| `Failed to initialize NVML: Driver/library version mismatch` (from a `nvidia-smi` call, or Dorado itself fails to see the GPU with no clearer message) | Kernel module out of sync with installed userspace driver package on this node — see §1.6 | Reboot the node (or `modprobe` reload if nothing else is using the GPU); this is a node-level fix, not a pipeline/params fix |
| Job completes but takes much longer than a comparable prior run, no error in `.command.err` | Possible thermal throttling — see §1.6 | Check `nvidia-smi --query-gpu=temperature.gpu,clocks_throttle_reasons.active` on the node if still accessible; compare wall-clock via `nextflow log` against prior runs |
| Exit 137, GPU memory looked fine | Host RAM exceeded (SLURM `memory = '40 GB'` on `nextflow.config`) | Bump `memory` for the `dorado` label in a `nextflow.config.<env>.local` override (`withLabel:`, not `withName:`) |

### samtools / seqtk (pixi-managed: `bam2fq`, `concat_fastq`, `total_bases`)

| Signature | Likely cause | Suggested fix |
|---|---|---|
| `pixi: command not found` | `pixi` isn't installed / on `$PATH` on the compute node that ran the job (common on SLURM worker nodes with a different environment than the login node) | Install pixi on all worker nodes, or point `PATH` at a shared pixi install; this is a per-cluster prerequisite the pipeline assumes silently |
| `error: no environment found` / lock mismatch from `pixi run` | `envs/<tool>/pixi.lock` out of sync with `pixi.toml`, or `.pixi/` not yet installed on this node | `pixi install --manifest-path $NANOBC_HOME/envs/<tool>/pixi.toml` once on that node (or ensure `envs/` including `.pixi/` is on shared storage) |
| `samtools: command not found` (inside the pixi run) | Broken/partial pixi env install | Re-run `pixi install --manifest-path $NANOBC_HOME/envs/samtools/pixi.toml --force-reinstall` |
| `awk: ... unexpected` in `bam2fq` | BAM has no `BC:Z:` tags at all (e.g. this BAM came from an LSK-style basecall accidentally routed through the barcode branch) | Confirm `--kitname` truly is a barcoded kit; check `samtools view <bam> | head -1` for a `BC:Z:` field |
| Almost all reads end up in `unknown.fastq.gz`, few/none in real barcode files | Reads genuinely weren't demultiplexed (kit/model mismatch, or basecalling ran without a barcoding-capable kit setting), not a script bug | Re-check `--kitname` and the Dorado invocation in `dorado_basecall` (`modules/dorado.nf:59-61`); this is a Dorado-level demux outcome, not something `bam2fq`'s awk script can fix |

### transfer (rsync/ssh, LSK path only)

| Signature | Likely cause | Suggested fix |
|---|---|---|
| `Permission denied (publickey)` | Passwordless SSH not set up from the compute/local node to `transfer_dest`'s host | Set up an SSH key accepted by the destination host for whichever user/node runs `transfer` (it's forced to `executor 'local'`, so it always runs on the Nextflow head node, not a SLURM worker) |
| `rsync: connection unexpectedly closed` / timeout | Destination host unreachable, wrong host/path in `--transfer_dest`, or a firewall | Test manually: `ssh <user>@<host> true` and `rsync --dry-run ...` before re-running |
| Retries exhausted (3x, per `errorStrategy 'retry'` / `maxRetries 3` on `transfer`) | Persistent (not transient) failure — the retry already absorbed transient blips | Fix the underlying connectivity/permission issue; `-resume` after fixing, don't just retry again |

### Resource / scheduler

| Signature in `nextflow.log` / `squeue` | Likely cause | Suggested fix |
|---|---|---|
| `Invalid Gres specification` | `--gres=gpu:3g.39gb:1` MIG profile doesn't exist on this cluster's GPU nodes | `nanobc-preflight` §2.5c/d — check `sinfo -o "%P %G"`, write an override |
| `Invalid partition name specified` | `highprio` or `cpu1` partition doesn't exist here | Same as above |
| Exit status 137 | SIGKILL = OOM (host RAM or, for `dorado`, possibly GPU memory) | See §1.5 |
| Exit status 143 | SIGTERM = timeout, preemption, or manual cancel | `nextflow run -resume` |

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

## 5. Resume vs re-run

- **Deterministic** failure (wrong kit/model path, missing file, wrong partition name) → fix the cause, then `nextflow run -resume` (picks up cached completed tasks).
- **Stochastic** failure (transient network blip on `transfer`, scheduler hiccup) → `-resume` is often enough on its own.
- **Upstream** failure (`dorado_basecall` produced a BAM with no real barcodes) → `-resume` won't help downstream `bam2fq`/`concat_fastq`; fix the basecalling parameters and re-run from scratch.

State which case applies in `diagnosis.md`.
