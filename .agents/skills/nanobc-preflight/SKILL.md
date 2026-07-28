---
name: nanobc-preflight
description: Prepare a Nextflow params.json for nf-nanopore-basecalling from a pod5 folder, a Dorado model, and a kit name, plus an optional machine-specific nextflow.config override. Use when the user has raw pod5 files but has not yet decided --kitname / --model / --dorado_bin / execution profile. Triggers: "set up nanopore basecalling", "preflight basecalling", "what params for dorado pipeline", "basecalling params.json", "nanobc preflight", "nextflow config local machine basecalling", "fix slurm partition dorado", "which dorado model".
---

# nanobc-preflight — nf-nanopore-basecalling parameter preparation

The pipeline `nextflow run main.nf` consumes a `-params-file params.json`. This skill produces that file plus a `params.rationale.md` audit trail. It does **not** run the pipeline.

## 0. Locate the pipeline

Resolve `NANOBC_HOME`:
- Prefer `$NANOBC_HOME` if set
- Otherwise look for a sibling directory named `nf-nanopore-basecalling` next to this skill's parent (`../nf-nanopore-basecalling`)
- Otherwise ask the user

```bash
: "${NANOBC_HOME:=$(cd "$SKILL_DIR/../../../nf-nanopore-basecalling" 2>/dev/null && pwd)}"
test -f "$NANOBC_HOME/main.nf" || { echo "Cannot locate nf-nanopore-basecalling. Set NANOBC_HOME."; exit 1; }
```

`samtools`/`seqtk` are pinned via pixi (`pixi run --manifest-path "$NANOBC_HOME/envs/<tool>/pixi.toml" ...`). **Dorado is not** — see §2b.

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

If zero files match, stop and ask the user to check the glob — Nextflow's `Channel.fromPath(params.pod5, checkIfExists: true)` (`main.nf:55`) will fail immediately with a similarly empty match, but catching it here saves a scheduler round-trip.

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
  *)     echo "Routes to: dorado_basecall -> bam2fq -> concat_fastq -> total_bases (barcode demux path)" ;;
esac
```

`main.nf:58` branches purely on `params.kitname.contains('LSK')`. There is no validation against a real ONT kit-name list in this pipeline — a typo (e.g. `SQK-LSK14` missing the trailing `4`) will silently either mis-route or get passed straight to Dorado's `--kit-name` flag and rejected there with a Dorado-level error. Read the kit name back to the user and confirm it before writing `params.json`.

### e) GPU check (both profiles need CUDA)

```bash
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv
else
  echo "WARNING: nvidia-smi not found on this host. Dorado basecaller -x cuda:all requires a CUDA-capable GPU."
fi
```

If this preflight is running on a login node that doesn't itself have a GPU (normal for SLURM), that's fine — the check matters on the node the job actually lands on. Note it as "not checked (submitted via SLURM)" in the rationale rather than failing.

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
- `slurm` — per-`withLabel:` blocks with hardcoded `clusterOptions`:
  - `dorado`: `--partition=highprio --gres=gpu:3g.39gb:1`, memory 40 GB (an A100 MIG 3g.39gb slice — a specific, cluster-specific GPU partition name and slice profile)
  - `samtools` / `seqtk`: `--partition=cpu1`, 2 cpus / 20 GB each
  - `transfer`: forced to `executor 'local'` regardless of profile

The `--partition=highprio --gres=gpu:3g.39gb:1` string is the single most cluster-specific line in this pipeline — it will not exist verbatim on any cluster other than the one it was written for.

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

  for p in highprio cpu1; do
    if ! sinfo -h -o "%P" | tr -d '*' | grep -qx "$p"; then
      echo "WARNING: partition '$p' hardcoded in nextflow.config is NOT available here"
    fi
  done
else
  echo "sinfo not available — cannot check partitions; will fall back to user-supplied names."
fi
```

If `highprio` is missing, or no partition on the cluster advertises a `gpu:3g.39gb` (or any `gpu:*`) gres, **do not silently substitute one** — ask the user which partition/gres string is correct for their cluster (or run `sinfo -o "%P %G"` together with them to pick one).

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
| `--transfer_dest` | Only ask/set for LSK kits — `main.nf:60-62` never calls `transfer` for the barcoded path regardless of this value |
| profile / override | From §2.5 |

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
- gpu (local check only): <nvidia-smi summary, or "not checked — submitted via SLURM">
- disk: <free space at outdir>

## Environment
- env_hint (auto): <slurm|local>
- env (user):      <slurm|local>
- slurm_partitions: <sinfo output, or "not on slurm">
- hardcoded_in_config: highprio (dorado gres gpu:3g.39gb:1), cpu1 (samtools/seqtk)
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
- Do **not** assume the `highprio` partition or `gpu:3g.39gb` gres exists on any cluster other than the one it was written for — always check with `sinfo` first
- Do **not** claim a specific Dorado basecalling throughput or runtime estimate — this repo has no benchmarking data pinned to a model/GPU pairing; point the user to their own prior runs or ONT's documentation instead of fabricating a number

## 6. Handoff

After writing `params.json` (+ optional override) + `params.rationale.md`, print the run command and stop. If the user says "go", invoke the run command yourself.
