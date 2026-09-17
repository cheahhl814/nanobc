---
name: nanobc-preflight
description: 'Prepare a Nextflow params.json for nf-nanopore-basecalling from a pod5 folder, a Dorado model, and a kit name, plus an optional machine-specific nextflow.config override. Validates the GPU is actually usable (nvidia-smi runs cleanly, no driver/library version mismatch, no pre-existing thermal throttling) before handing off to a run. Use when the user has raw pod5 files but has not yet decided --kitname / --model / --dorado_bin / execution profile, or wants to confirm the GPU is healthy before a long run.'
version: 1.1.0
updated: "2026-09-17"
triggers:
  - "set up nanopore basecalling"
  - "preflight basecalling"
  - "what params for dorado pipeline"
  - "basecalling params.json"
  - "nanobc preflight"
  - "nextflow config local machine basecalling"
  - "fix slurm partition dorado"
  - "which dorado model"
  - "check gpu before running dorado"
  - "is my gpu ok for basecalling"
---

# nanobc-preflight — nf-nanopore-basecalling parameter preparation

> **v1.1.0.** Phase 1 of the `nanobc-*` bundle: validates pod5/model/kit/GPU/cluster evidence, then writes `params.json` + `params.rationale.md` (+ optional `nextflow.config.<env>.local`). It does **not** run the pipeline.

## Audience

This skill serves two purposes:

- **AI Agents**: Triggered by the phrases above. Must run **all** evidence-collection steps (§2, never skip), write the artifacts in §4, and record a verdict.
- **Human Users**: Provides a transparent audit trail — `params.rationale.md` is the only place Dorado's unpinned version and every pre-run decision get recorded.

## When to Use This Skill

Use this skill when:

- The user has raw pod5 files and has not yet decided `--kitname` / `--model` / `--dorado_bin` / execution profile
- The user wants to confirm the GPU (driver, thermals) is healthy before committing to a long run
- A `nextflow.config` override is needed because the hardcoded SLURM partition/gres doesn't match this cluster

Do NOT use this skill if:

- `params.json` already exists and is still valid — verify it instead; re-running overwrites it
- A run already failed and needs interpreting → `nanobc-debug`
- A run already finished and needs QC → `nanobc-qc`
- The user wants to launch the run — this skill writes the params, `nanobc-run` executes

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path | Source | Required? |
| --- | --- | --- |
| `$NANOBC_HOME/main.nf` + `nextflow.config` | pipeline repo (resolved in §0.1) | yes |
| Pod5 glob | user (§1) | yes |
| Dorado model path | user (§1) | yes |
| Kit name | user (§1) | yes (default `SQK-LSK114`) |
| Dorado binary path | user (§1) | no (default `dorado` on `$PATH`) |
| Transfer destination `user@host:/path` | user (§1) | no (LSK only) |
| Output / run directory | user (§1) | no (new per-sample dir) |

### Outputs (produced)

| Path | Owner | Format | Notes |
| --- | --- | --- | --- |
| `$RUN_DIR/params.json` | this skill | JSON | all six keys, absolute paths for `pod5`/`model`/`outdir` |
| `$RUN_DIR/params.rationale.md` | this skill | Markdown | evidence audit + **overall verdict** (§4) |
| `$RUN_DIR/nextflow.config.<env>.local` | this skill | Nextflow config | optional — only on partition/gres mismatch or user request (§2.5d) |

### Verdict gate

`nanobc-run` **refuses to execute** `nextflow run` unless `$RUN_DIR/params.json` exists **and** `$RUN_DIR/params.rationale.md` records an overall verdict of `GO` or `GO-WITH-WARNINGS` (see §4 + Interpretation Guidelines). A `NO-GO` verdict stops the pipeline — the failing checks must be fixed and this skill re-run first.

### 0.1 Locate the pipeline

Resolve `NANOBC_HOME`:
- Prefer `$NANOBC_HOME` if set
- Otherwise look for a sibling directory named `nf-nanopore-basecalling` next to this skill's parent (`../nf-nanopore-basecalling`)
- Otherwise ask the user

```bash
: "${NANOBC_HOME:=$(cd "$SKILL_DIR/../../../nf-nanopore-basecalling" 2>/dev/null && pwd)}"
test -f "$NANOBC_HOME/main.nf" || { echo "Cannot locate nf-nanopore-basecalling. Set NANOBC_HOME."; exit 1; }
```

`samtools`/`seqtk` are pinned via pixi (`pixi run --manifest-path "$NANOBC_HOME/envs/<tool>/pixi.toml" ...`). **Dorado is not** — see §2b.

### 0.5 Ask-User Stop Points

This sub-skill has **five** stop points (SP1–SP5). Each fires only when the evidence is ambiguous; the format is **Evidence + Recommend + Options**.

#### SP1 — Execution environment

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| Profile needed for `params.json` + override naming | SLURM_JOB_ID/SLURM_CLUSTER_NAME hint (§2.5b) conflicts with the user's answer, or neither is decisive | "slurm or local?" |

**Auto-pick when**: the hint is unambiguous (SLURM vars set → `slurm`; workstation without scheduler → `local`) — proceed silently.

#### SP2 — SLURM partition/gres mismatch

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| `sinfo` (§2.5c) lacks the (placeholder) partitions the shipped config requests — or any GPU-class gres at all | Placeholder config values are NOT usable on this cluster | "Which partition/gres should the `dorado` (and `samtools`/`seqtk`) labels use here?" — offer the sinfo output as evidence |

**Auto-pick when**: never — do **not** silently substitute a partition/gres (§2.5d).

#### SP3 — GPU unusable on a local profile

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| `nvidia-smi` present but fails to run, or reports a driver/library version mismatch (§2e) | Loaded vs installed driver versions differ | "Fix now (reboot / modprobe reload), or submit to a working GPU node via `slurm` instead?" |

**Auto-pick when**: never for a `local` profile — do not write `params.json` with a `local` profile while `nvidia-smi` cannot run on this host.

#### SP4 — Kit/model confirm-back

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| Kit name read-back (§2d) or model-path existence (§2c) is surprising (e.g. a typo'd kit silently mis-routes) | `LSK` vs barcode routing + model on disk | "`--kitname SQK-LSK114` routes to the LSK path and `--model <path>` exists — confirm?" |

**Auto-pick when**: the user typed the kit/model themselves just now and §2d routing matches expectation → confirm-back in one line without stopping.

#### SP5 — Model not on disk

| Trigger | Evidence check | Ask |
| --- | --- | --- |
| Model path MISSING (§2c) | Model hasn't been downloaded yet | "Download it now (`$DORADO_BIN download --model <model>`), or did you mean a different model path?" |

**Auto-pick when**: never invent a model name; if the user names a different existing path, use it.

#### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** When asking, present the evidence first, then the recommendation, then 2–4 concrete options. Do not ask "what do you want?" — ask "I see X, recommend Y, which one of A/B/C?"

## 1. Gather inputs from the user

Ask once, in one question batch if possible:

| Input | Required? | Default if absent |
|---|---|---|
| Pod5 glob (e.g. `input_folder/N046/*.pod5`) | yes | — |
| Dorado model path (e.g. `dna_r10.4.1_e8.2_400bps_sup@v5.2.0`) | yes | — |
| Kit name (e.g. `SQK-LSK114`, `SQK-RBK114`) | yes | `SQK-LSK114` |
| Dorado binary path | no | `dorado` (assumed on `$PATH`) |
| Transfer destination `user@host:/path` | no (LSK only) | skip transfer |
| Output/run directory | no | a new directory per sample, e.g. `results/<sample>` |

## 2. Compute evidence (always run; never skip)

### a) Pod5 inventory

```bash
POD5_GLOB="input_folder/N046/*.pod5"   # from user
shopt -s nullglob
files=( $POD5_GLOB )
echo "pod5 files matched: ${#files[@]}"
du -ch "${files[@]}" 2>/dev/null | tail -1
```

If zero files match, stop and ask the user to check the glob — Nextflow's `Channel.fromPath(params.pod5, checkIfExists: true)` (`main.nf:64`) will fail immediately with a similarly empty match, but catching it here saves a scheduler round-trip.

### b) Dorado binary and version (not pixi-managed — record it)

```bash
DORADO_BIN="${DORADO_BIN:-dorado}"
if command -v "$DORADO_BIN" >/dev/null 2>&1; then
  DORADO_VERSION=$("$DORADO_BIN" --version 2>&1 | head -1)
  echo "dorado found: $(command -v "$DORADO_BIN") ($DORADO_VERSION)"
else
  echo "WARNING: '$DORADO_BIN' not found on PATH. Pass an absolute --dorado_bin path."
fi
```

Because Dorado has no conda/pixi package, its version is **not** pinned anywhere in the repo. Recording `dorado --version` here is the only per-run audit trail for it — always capture it in `params.rationale.md`.

### c) Model path check

```bash
MODEL="dna_r10.4.1_e8.2_400bps_sup@v5.2.0"   # from user, may be relative or absolute
if [ ! -e "$MODEL" ]; then
  echo "WARNING: model path '$MODEL' does not exist relative to cwd."
  echo "If it hasn't been downloaded yet, try: $DORADO_BIN download --model $MODEL"
  echo "(check '$DORADO_BIN download --help' for exact flags — they vary by Dorado version)"
fi
```

Never invent a model name. If the user is unsure which model matches their flow cell/kit, ask them to check the sequencing run report or `$DORADO_BIN download --list` (or equivalent for their installed version) rather than guessing.

### d) Kit name sanity check

```bash
KITNAME="SQK-LSK114"   # from user
case "$KITNAME" in
  *LSK*) echo "Routes to: dorado_basecall_lsk -> (optional) transfer" ;;
  *)     echo "Routes to: dorado_basecall -> bam2fq (barcode demux path)" ;;
esac
```

`main.nf:67` branches purely on `params.kitname.contains('LSK')`. There is no validation against a real ONT kit-name list in this pipeline — a typo (e.g. `SQK-LSK14` missing the trailing `4`) will silently either mis-route or get passed straight to Dorado's `--kit-name` flag and rejected there with a Dorado-level error. Read the kit name back to the user and confirm it before writing `params.json`.

### e) GPU check (both profiles need CUDA)

```bash
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,memory.total,memory.free,temperature.gpu,clocks_throttle_reasons.active --format=csv
else
  echo "WARNING: nvidia-smi not found on this host. Dorado basecaller -x cuda:all requires a CUDA-capable GPU."
fi
```

If this preflight is running on a login node that doesn't itself have a GPU (normal for SLURM), that's fine — the check matters on the node the job actually lands on. Note it as "not checked (submitted via SLURM)" in the rationale rather than failing.

**If `nvidia-smi` itself fails to run** (rather than just "not found"), don't treat that as "no GPU" — it usually means the GPU exists but the driver is broken:

```bash
if command -v nvidia-smi >/dev/null 2>&1 && ! nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi is present but failed to run — checking for a driver/library version mismatch:"
  nvidia-smi 2>&1 | head -3

  LOADED_VERSION=$(cat /proc/driver/nvidia/version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  INSTALLED_PKG=$(dpkg -l 2>/dev/null | awk '/nvidia-driver-[0-9]+/ {print $2, $3}')
  echo "Loaded kernel module version: ${LOADED_VERSION:-unknown}"
  echo "Installed driver package:     ${INSTALLED_PKG:-unknown (not a dpkg-managed install, or check rpm/pacman)}"
  echo ""
  echo "A mismatch here (installed userspace libs newer/older than the loaded kernel module)"
  echo "almost always means a driver package was updated without reloading the kernel module."
  echo "Fix: reboot, or if nothing else is using the GPU:"
  echo "  sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia && sudo modprobe nvidia"
fi
```

**Do not proceed to write `params.json` with a `local` profile** if `nvidia-smi` cannot run at all on this host — Dorado will fail immediately with "no CUDA-capable device is detected" or similar. Surface the mismatch/fix to the user and get it resolved (or confirm they're submitting to a different, working GPU node via `slurm`) before finishing preflight.

### e.1) Temperature / throttling sanity check (record even when nvidia-smi works fine)

```bash
# temperature.gpu is near-universally supported; the rest (temperature.memory,
# clocks_throttle_reasons.*) vary by GPU/driver/NVML version and have NOT been
# confirmed to work on this exact host — query them one at a time and fall back
# gracefully rather than assume the combined query below always succeeds:
nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader
nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv,noheader 2>&1 \
  || echo "clocks_throttle_reasons.active not supported on this driver/GPU — skip, note as 'not available' in rationale, don't fail preflight over it"
nvidia-smi --query-gpu=temperature.memory --format=csv,noheader 2>&1 \
  || echo "temperature.memory not supported here — same handling"
```

If any field returns `[Not Supported]` (a normal NVML response, not an error) or the whole call fails non-zero (an unsupported-field-in-combined-query edge case on some driver versions), treat it as "not available on this host" and move on — do not block preflight on a missing optional field. Only `temperature.gpu` failing to return at all is worth escalating (that usually means the driver/library mismatch in §2e, not a missing-field issue).

| Observation | Note in rationale |
|---|---|
| Temp comfortably below the card's throttle point (check `nvidia-smi -q -d TEMPERATURE` for the card's own `Slowdown Temp`/`Shutdown Temp` thresholds — these vary by model, don't assume a fixed number), no throttle reasons active | ✅ normal |
| `clocks_throttle_reasons.active` shows `SW Thermal Slowdown` or `HW Slowdown` | ⚠️ GPU is already throttling *before the run even starts* — likely a airflow/dust/fan problem in the chassis, worth checking physically before committing a long basecalling job to it |
| `nvidia-smi` reports a temperature but the host has no fan-speed sensor exposed (`sensors` shows nothing GPU-related) | note only — most workstation/server GPUs manage their own fan curve internally and don't expose a controllable fan-speed knob to the OS; this is expected, not a defect |

This is a **snapshot at preflight time**, not continuous monitoring — Dorado runs can take hours, and thermal throttling is a sustained-load phenomenon that a single check before the run won't catch. See `nanobc-debug` §1.5 for what to check if a run finishes slower than expected or a temperature-related failure shows up mid-run.

**Known local workstation GPU**: record this host's GPU — name, VRAM, TDP, PCI ID, driver/`nvidia-settings` versions — in `../gpu-host-notes.md` (gitignored; machine inventory is never pushed). Then adapt the generic guidance above to what it records:

- **Very large VRAM class (e.g. 96 GB professional cards)**: CUDA OOM is very unlikely — far more than any current Dorado model + batch size needs. If a CUDA-OOM error does show up on such a host, look harder at a config/params bug (e.g. an accidental `--gres` MIG-slice limit) before assuming the model is just "too big" — that diagnosis fits a shared/MIG-partitioned card, not a big single card.
- **Lower-power / Max-Q-class variants (e.g. 300 W vs. ~600 W standard)**: they trade cooling headroom for power/noise. Dorado basecalling is a long, steady, near-100%-utilization load — a different thermal profile than what their cooling is typically validated against. Take the §2e.1 temperature/throttle snapshot more seriously on such a host, and if `nanobc-debug` §1.6 ever shows throttling there, that's plausible, not surprising.
- **SLURM gres mismatch**: the shipped `nextflow.config` `dorado` label carries **placeholder** `--gres`/`--partition` values (e.g. an A100-80GB MIG-slice profile from a different cluster, historically). They **do not describe this workstation's GPU at all** — go through the §2.5c/d partition/gres check regardless of how confident a hardcoded value looks.

### e.2) Fan control helper (optional, local workstation only)

`$SKILL_DIR/gpu-fan.sh` is a small manual helper for forcing the GPU fan to 100% before a long Dorado run and handing the curve back to firmware afterward. It drives the fans over X11/NV-CONTROL via `nvidia-settings` — **not** `nvidia-smi` (which can only *query* `fan.speed`). It only makes sense on a `local`-profile workstation; on SLURM you don't control the compute node's fans.

```bash
"$SKILL_DIR/gpu-fan.sh" status          # read-only: temp, fan %, control state, target, RPM
"$SKILL_DIR/gpu-fan.sh" max             # force fan to 100%, verify read-back
"$SKILL_DIR/gpu-fan.sh" set 80          # force a specific percent
"$SKILL_DIR/gpu-fan.sh" auto            # return fan curve to GPU firmware
```

Use `max` before committing a long `local` run — Dorado is a sustained near-100%-utilization load, exactly the profile the Max-Q cooler (§2e.1) is least validated against. **There is no auto-restore**: fans stay at max until `gpu-fan.sh auto` is run, so note the restore step to the user when you hand off to the run.

**Attribute names vary by driver — the script probes both** (`GPUTargetFanSpeed`, `GPUFanControlTarget`) and picks the working one automatically. Record what worked on this host — control state, attribute, `nvidia-settings`/driver versions — in `../gpu-host-notes.md` (gitignored).

| Scenario | Behavior |
|---|---|
| `nvidia-settings` not installed, or no reachable X display (`DISPLAY` unset/headless) | `set`/`max`/`auto` exit non-zero with a clear message; `status` still prints the `nvidia-smi` snapshot |
| Neither `GPUTargetFanSpeed` nor `GPUFanControlTarget` is queryable | Reports "firmware-controlled fan, no OS knob" — most professional/datacenter cards; don't treat as a defect |
| Write succeeds but read-back doesn't match | Prints a warning — manual fan control unsupported on this driver/GPU |

### f) Disk space check

```bash
: "${OUTDIR:=$NANOBC_HOME/results}"
df -BG "$OUTDIR" 2>/dev/null | awk 'NR==2 {print "Free space at outdir:", $4}'
du -sh "${files[@]}" 2>/dev/null | tail -1   # total pod5 input size, from §2a
```

Basecalled FASTQ/BAM output is typically smaller than raw pod5 input, but leave headroom — recommend at least as much free space as the input pod5 total.

## 2.5 Profile and cluster-spec detection (run before §3)

`nextflow.config` ships two profiles:

- `local` — `executor = 'local'`; per-label resources are already set directly in the config (`dorado`: 4 cpus/40 GB, `samtools`/`seqtk`: 2 cpus/20 GB each). Unlike some pipelines, `local` here is **not** underprovisioned by default — but it still assumes a local GPU exists.
- `slurm` — per-`withLabel:` blocks with **placeholder** `clusterOptions`:
  - `dorado`: `--partition=<gpu_partition> --gres=gpu:<gpu_gres>:1`, memory 40 GB
  - `samtools` / `seqtk`: `--partition=<cpu_partition>`, 2 cpus / 20 GB each
  - `transfer`: forced to `executor 'local'` regardless of profile

The placeholder clusterOptions strings are the single most cluster-specific part of this pipeline — they will not run on any real cluster until replaced with real partition/gres names via a `nextflow.config.<cluster>.local` override (gitignored; your real values live there, applied via `-c`).

### a) Ask the execution environment (one question)

```
? Execution environment
  - slurm : HPC cluster with SLURM scheduler
  - local : workstation (no scheduler), needs a local CUDA GPU
```

### b) Detect environment (auto; never skip)

```bash
if [ -n "$SLURM_JOB_ID" ] || [ -n "$SLURM_CLUSTER_NAME" ]; then
  ENV_HINT=slurm
else
  ENV_HINT=local
fi
echo "Detected execution environment: $ENV_HINT"
```

This is a hint; the user's answer in §2.5a wins.

### c) SLURM partition + gres check (for `slurm` environment)

```bash
if command -v sinfo >/dev/null 2>&1; then
  echo "Partitions on this cluster:"
  sinfo -h -o "%P %G" | sort -u

  for p in <gpu_partition> <cpu_partition>; do
    if ! sinfo -h -o "%P" | tr -d '*' | grep -qx "$p"; then
      echo "WARNING: partition '$p' (placeholder from nextflow.config) is NOT available here"
    fi
  done
else
  echo "sinfo not available — cannot check partitions; will fall back to user-supplied names."
fi
```

If the (placeholder) partitions are missing — or no partition on the cluster advertises a GPU-class gres at all — **do not silently substitute one** — ask the user which partition/gres string is correct for their cluster (or run `sinfo -o "%P %G"` together with them to pick one).

### d) Write the user-side override file (only if needed)

Generate `nextflow.config.<env>.local` **next to `params.json`** in the run directory, applied via `-c`:

```bash
cat > nextflow.config.slurm.local <<'EOF'
// Auto-generated by nanobc-preflight on <ISO8601>
// Detected partitions: <sinfo output summary>
// Applied at run time:  nextflow run main.nf -profile slurm -c nextflow.config.slurm.local -params-file params.json

profiles {
    slurm {
        process {
            withLabel: 'dorado' {
                clusterOptions = '--partition=<real_gpu_partition> --gres=gpu:<real_gres>:1 --job-name=dorado'
            }
            withLabel: 'samtools' {
                clusterOptions = '--partition=<real_cpu_partition> --job-name=samtools'
            }
            withLabel: 'seqtk' {
                clusterOptions = '--partition=<real_cpu_partition> --job-name=seqtk'
            }
        }
    }
}
EOF
```

**Use `withLabel:`, not `withName:`.** This pipeline's processes carry `label 'dorado' | 'samtools' | 'seqtk' | 'transfer'` directives (see `modules/dorado.nf`), not distinct per-process names being targeted individually — a `withName:` block here would silently do nothing for the labeled resource blocks. (This is the opposite convention from BettaMt, which has no `label` directives and must use `withName:` — don't copy that guidance verbatim between pipelines.)

The original `nextflow.config` is **never modified**. If the user re-runs on a different cluster, regenerate or hand-edit the override.

## 3. Reasoning framework

This pipeline takes user-declared values (kit, model, transfer target) almost verbatim — there's no coverage/size heuristic to compute like in assembly pipelines. The reasoning here is mostly **validation**, not derivation:

| Decision | Rule |
|---|---|
| `--kitname` | Take the user's value verbatim after the LSK/non-LSK routing check (§2d) and an explicit confirm-back |
| `--model` | Must exist on disk (§2c); never invent a model name from a "similar" flow cell |
| `--dorado_bin` | Absolute path if not confirmed on `$PATH` (§2b) |
| `--transfer_dest` | Only ask/set for LSK kits — `transfer` is only invoked in the LSK branch (`main.nf:68-71`); the barcoded branch (`main.nf:72-75`) never calls it regardless of this value |
| profile / override | From §2.5 |

## Interpretation Guidelines

The overall verdict is written into `params.rationale.md` (§4):

- **GO**: all evidence checks pass with confident values — GPU clean, model on disk, kit confirmed, partitions verified (or `local` profile with a working `nvidia-smi`). `nanobc-run` may execute.
- **GO-WITH-WARNINGS**: at least one non-blocking check is in warning territory (e.g. `clocks_throttle_reasons.active` unsupported on this driver, `dorado` not on `$PATH` but an absolute `--dorado_bin` was supplied, thermal snapshot borderline). Proceed **but surface the warnings** to the user before the run.
- **NO-GO**: at least one blocking check fails — `dorado` binary unresolvable, model path missing, `nvidia-smi` cannot run on a `local` profile, partition/gres mismatch with no override agreed, zero pod5 files matched. **Stop**; fix and re-run this skill (it overwrites the artifacts).

## Troubleshooting — Signature library

When an evidence step itself fails, match against these patterns. **Always** read the actual error before concluding.

| Signature in stderr | Likely cause | Suggested fix |
| --- | --- | --- |
| `Failed to initialize NVML: Driver/library version mismatch` (from `nvidia-smi`) | Driver package updated without reloading the kernel module (§2e) | Reboot, or `sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia && sudo modprobe nvidia` if nothing else is using the GPU. On a shared SLURM node, report to admins. |
| `No devices were found` / `no CUDA-capable device is detected` | GPU absent or invisible on this host/cgroup | `local` profile → NO-GO; `slurm` → note "not checked — submitted via SLURM" in the rationale |
| `[Not Supported]` from a single NVML query field | Field unsupported on this driver/GPU — a normal NVML response, not an error | Note "not available" in the rationale; don't fail preflight over it (§2e.1) |
| `nvidia-smi: command not found` | Driver userspace not installed on this host | `local` → NO-GO; `slurm` → note not checked |
| `sinfo: command not found` | No SLURM on this host (normal for `local`) | Fall back to user-supplied partition names (§2.5c) |
| `jq: command not found` | jq missing | Install jq (distro package or `pixi add jq`) — the `nanobc-*` skills read `params.json` with it |
| Model path MISSING (§2c) | Model not downloaded yet | `$DORADO_BIN download --model <model>` (check its `--help`; flags vary by version) |
| Zero pod5 files matched (§2a) | Wrong glob | Stop and fix the glob with the user before writing params — Nextflow's `checkIfExists: true` would fail anyway |
| `gpu-fan.sh` `set`/`max` exits non-zero | `nvidia-settings` missing or no reachable X display (§2e.2) | `status` still prints the `nvidia-smi` snapshot; don't block the run over fan control |

## 4. Output contract — write exactly these files

### `params.json`

```json
{
  "pod5":          "/abs/path/to/N046/*.pod5",
  "outdir":        "/abs/path/to/results/N046",
  "kitname":       "SQK-LSK114",
  "model":         "/abs/path/to/dna_r10.4.1_e8.2_400bps_sup@v5.2.0",
  "dorado_bin":    "dorado",
  "transfer_dest": ""
}
```

- All six keys are required by `main.nf`'s defaults, but only `pod5` and `model` are enforced (main.nf exits early if either is empty) — always fill in all six anyway for a self-documenting params file.
- Use absolute paths for `pod5`, `model`, `outdir` — the pod5 glob is expanded by Nextflow at the launch working directory, and a relative glob silently breaks if the run is later resumed from a different cwd.

### `nextflow.config.<env>.local` (only if §2.5 found a mismatch or the user wants one)

See §2.5d for the template.

### `params.rationale.md`

```markdown
# nf-nanopore-basecalling preflight rationale

Generated: <ISO8601>
Pipeline:  $NANOBC_HOME (commit <hash if available>)

## Evidence
- pod5: <glob>, n=<count> files, total=<size> (`du -ch`)
- dorado: <path>, version=<dorado --version output, or "not found — resolve before running">
- model: <path> (<exists|MISSING>)
- kitname: <value> → routes to <LSK path | barcode-demux path>
- gpu (local check only): <nvidia-smi name/memory summary, or "not checked — submitted via SLURM">
- gpu driver check: <nvidia-smi ran cleanly | driver/library version mismatch found: loaded=<X> installed=<Y> — resolved by reboot/modprobe before running>
- gpu temperature/throttle (snapshot): <temp>°C, throttle_reasons=<none|list> (see nanobc-preflight §2e.1; one-time check, not continuous monitoring)
- disk: <free space at outdir>

## Environment
- env_hint (auto): <slurm|local>
- env (user):      <slurm|local>
- slurm_partitions: <sinfo output, or "not on slurm">
- hardcoded_in_config: <gpu_partition>/<gpu_gres> (dorado), <cpu_partition> (samtools/seqtk) — placeholders by default
- partition_mismatch: <none | list of missing partitions/gres>

## Config override
- wrote: <nextflow.config.<env>.local, or "none — cluster matches hardcoded config">

## Decisions
- --kitname <value>: <LSK path / barcode path>, confirmed with user
- --model <path>: verified present on disk
- --dorado_bin <path>: <on PATH | absolute path supplied>
- --transfer_dest <value or "(skipped)">: <reason>

## Warnings
- (none, or list any that fired)

## Overall verdict

**GO** ✅ *(or GO-WITH-WARNINGS ⚠️ / NO-GO ❌)*

<one-line summary>

## Run command
\`\`\`bash
cd "$NANOBC_HOME"
nextflow run main.nf -profile <env> [-c nextflow.config.<env>.local] -params-file params.json
\`\`\`
```

## 5. What NOT to do

- Do **not** invent a Dorado model name or kit name the user hasn't confirmed
- Do **not** run `nextflow run` — this skill produces the params, the user (or `nanobc-run`) runs the pipeline
- Do **not** write to `$NANOBC_HOME/results/` — that's the pipeline's own output directory
- Do **not** edit `$NANOBC_HOME/nextflow.config` in place — always use a `nextflow.config.<env>.local` override via `-c`
- Do **not** use `withName:` in the override — this pipeline targets processes by `label` (`dorado`, `samtools`, `seqtk`, `transfer`); use `withLabel:`
- Do **not** assume the shipped placeholder partition/gres (`<gpu_partition>` / `<gpu_gres>`) exists on any cluster — always check with `sinfo` first
- Do **not** claim a specific Dorado basecalling throughput or runtime estimate — this repo has no benchmarking data pinned to a model/GPU pairing; point the user to their own prior runs or ONT's documentation instead of fabricating a number

## Verification

- [ ] `$RUN_DIR/params.json` exists, is valid JSON, carries all six keys, and uses absolute paths for `pod5` / `model` / `outdir`.
- [ ] `$RUN_DIR/params.rationale.md` exists with Evidence / Environment / Config override / Decisions / Warnings / **Overall verdict** sections filled.
- [ ] `dorado --version` output is recorded in the rationale (the only Dorado audit trail — it is not pixi/conda-pinned).
- [ ] Kit name was confirmed back with the user and its routing (LSK vs barcode-demux) is stated in the rationale.
- [ ] Any override file uses `withLabel:` (never `withName:`), is applied via `-c`, and `$NANOBC_HOME/nextflow.config` itself is untouched.
- [ ] Overall verdict is `GO` or `GO-WITH-WARNINGS` before handing off — `nanobc-run` refuses a `NO-GO` verdict (Verdict gate, §0).

## 6. Handoff

After writing `params.json` (+ optional override) + `params.rationale.md`, print the run command and stop. If the user says "go", invoke the run command yourself.

The recommended handoff message:

> nanobc-preflight complete. Overall verdict: `<GO | GO-WITH-WARNINGS | NO-GO>`. Artifacts: `params.json`, `params.rationale.md` (+ `nextflow.config.<env>.local`). Next: invoke `nanobc-run` — it will confirm (SP1) and execute the run command above.
