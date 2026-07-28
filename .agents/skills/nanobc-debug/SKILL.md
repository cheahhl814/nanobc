---
name: nanobc-debug
description: Interpret a failed nf-nanopore-basecalling Nextflow run, including CUDA/GPU errors, Dorado model/kit errors, pixi env issues, and SLURM partition/gres mismatches. Use when nextflow log shows ERR, exit status 1, exit 137 (OOM-kill), or a Dorado/samtools/seqtk/transfer process failed. Triggers: "basecalling failed", "dorado error", "why did the pipeline fail", "nextflow failure", "nanobc debug", "CUDA out of memory dorado", "pixi command not found", "unknown barcode fastq empty", "rsync transfer failed".
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
