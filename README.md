# nanobc

[![Version](https://img.shields.io/badge/version-2.0.0-blue)](#-installation)
[![Built with](https://img.shields.io/badge/built%20with-skill--forge-orange)](https://github.com/cheahhl814/skill-forge)
[![Shape](https://img.shields.io/badge/shape-dual--path%20pipeline%20skill-8A2BE2)](#-pipeline-overview)

A Dorado-based Nanopore basecalling **agent skill** following the
[skill-forge](https://github.com/cheahhl814/skill-forge) convention: a root
`SKILL.md` router, four phase sub-skills (`preflight/`, `run/`, `debug/`,
`qc/`) forming a verdict-gated **filesystem evidence chain**, and a dual
execution path — the **Nextflow DSL2 runner** (`runners/nextflow-runner/`,
source of truth) for HPC/cohort runs and **manual bash recipes**
(`runners/bash-recipes/`) for single-machine / no-Nextflow situations.

**Repository**: https://github.com/cheahhl814/nanobc

> [!NOTE]
> Skill **v2.0.0** (restructured from the v1.2.x `.agents/skills/` bundle
> layout) · pipeline **v0.1.1** (multi-chunk publishDir-overwrite fix) ·
> updated 2026-10-18.

## Contents

- [Installation](#-installation)
- [Usage](#-usage)
- [Pipeline overview](#-pipeline-overview)
- [Tools](#-tools)
- [Update check](#-update-check)
- [Repository layout](#-repository-layout)
- [Hard guarantees](#-hard-guarantees)
- [Scope notes](#-scope-notes)
- [Provenance](#provenance)

## 🚀 Installation

**Option A — give your agent this prompt (recommended):**

```text
Install the nanobc agent skill from https://github.com/cheahhl814/nanobc —
clone it and make the checkout root visible in your agent's skills directory
(the path your agent watches for skills — symlink the root directory itself;
the root SKILL.md router is the entry point). Then read SKILL.md and each
sub-skill SKILL.md (preflight/nanobc-preflight, run/nanobc-run,
debug/nanobc-debug, qc/nanobc-qc) to understand the phases and the
Input/Output contracts. Confirm when the environment is ready.
```

**Option B — manual install (per user):**

```bash
git clone https://github.com/cheahhl814/nanobc.git
# Symlink the skill root (the directory holding SKILL.md) into your agent's
# skills directory:
ln -s "$(pwd)/nanobc" <your-agents-skills-dir>/nanobc
```

**Pipeline runtime** (needed wherever a run actually executes):

- [Nextflow](https://www.nextflow.io/) >= 23.04 (>= 25.06 for the `-preview`
  dry-run flag) — mode `nextflow` only
- [Dorado](https://github.com/nanoporetech/dorado) — a standalone GPU binary
  from ONT; put it on `$PATH` or point `--dorado_bin` at it. A CUDA-capable
  GPU is required for basecalling in **both modes**
- [pixi](https://pixi.sh/) — `samtools`/`seqtk` resolve through pinned
  environments on demand (`runners/nextflow-runner/envs/<tool>/`); no manual
  install of these tools is needed

> [!TIP]
> No GPU, no dorado binary, no model on your machine? The skill still fully
> verifies itself: `bash runners/nextflow-runner/test_pipeline_smoke.sh` and
> `bash runners/bash-recipes/test_smoke.sh` run the real pipeline and recipes
> end-to-end against a deterministic fake-dorado stub, CPU-only.

## 💡 Usage

The skill is designed to be driven by an AI agent: the root `SKILL.md` detects
the current stage from the filesystem state of your run directory and routes to
the right sub-skill.

### Natural-language prompts that trigger the skill

```text
Run the basecalling pipeline / basecall this pod5 folder      → run phase
Set up nanopore basecalling / which dorado model              → preflight phase
Fix slurm partition dorado / check gpu before running         → preflight phase
Basecalling failed / why did the pipeline fail                → debug phase
Check basecalling output / did the demux work                 → qc phase
```

### Manual phase execution

Set a run directory — all phase artifacts land there — and invoke the
sub-skill you need:

```bash
RUN_DIR=/path/to/run-dir          # one per sample / pod5 batch

# Phase 1 — validate pod5/model/kit/GPU/cluster/execution-mode,
#           write params.json + params.rationale.md
# Phase 2 — execute the run (mode from params.json:execution_mode)
# Phase 3 — on failure: interpret via the signature library, write diagnosis.md
# Phase 4 — check output integrity, write report.md
```

### Quick start — pipeline

**Nextflow runner** (HPC/SLURM, cohort, trace/report/timeline artifacts):

```bash
cd runners/nextflow-runner
nextflow run main.nf -profile slurm \
  --pod5   "input_folder/N046/*.pod5" \
  --model  /path/to/dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
  --kitname SQK-LSK114
```

**Manual bash recipes** (single machine, no Nextflow required — still needs
the CUDA GPU + dorado + model):

```bash
./runners/bash-recipes/run_basecalling.sh \
  --pod5   "input_folder/N046/*.pod5" \
  --model  /path/to/dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
  --kitname SQK-LSK114 --outdir ./results/N046
```

`--pod5` and `--model` are required in both modes; execution aborts early
without them. See
[`runners/nextflow-runner/README.md`](runners/nextflow-runner/README.md) for
the full parameter table and
[`runners/bash-recipes/README.md`](runners/bash-recipes/README.md) for the
two-mode trade-off table.

## 🔬 Pipeline overview

| # | Phase | Goal | Sub-skill | Artifact produced |
|:--|:------|:-----|:----------|:------------------|
| **1** | **Preflight** | Validate pod5/model/kit/GPU/cluster + execution mode, write params | `preflight/nanobc-preflight` | `$RUN_DIR/params.json` (incl. `execution_mode`) + `params.rationale.md` (+ optional `nextflow.config.<env>.local`) |
| **2** | **Run** | Execute the run, mode from `params.json:execution_mode` | `run/nanobc-run` | FASTQs under `$OUTDIR` — identical layouts in both modes |
| **3** | **Debug** | Interpret a failed run | `debug/nanobc-debug` | `$RUN_DIR/diagnosis.md` (top-3 ranked hypotheses + Option A/B fixes) |
| **4** | **QC** | Check output integrity + read counts | `qc/nanobc-qc` | `$RUN_DIR/report.md` (overall PASS / PASS-WITH-WARNINGS / FAIL) |

Two paths through the pipeline, selected by `--kitname`:

- **LSK kits** (e.g. `SQK-LSK114`): `dorado_basecall_lsk` emits FASTQ directly;
  optionally rsynced to a remote destination via `--transfer_dest`.
- **Barcoded kits** (e.g. `SQK-RBK114`): `dorado_basecall` emits a BAM, which
  is demultiplexed per barcode (`bam2fq`, per-chunk files named
  `<chunk-id>_<barcode>.fastq.gz`), then `concat_fastq` aggregates each
  barcode across chunks — a single `<barcode>.fastq.gz` per barcode published
  to `<outdir>/fastq/` (incl. `unknown.fastq.gz`).

> [!IMPORTANT]
> Each sub-skill has an explicit **Inputs / Outputs contract** at the top of
> its `SKILL.md`, and phases are **verdict-gated**: `nanobc-run` refuses to
> execute the run unless `params.rationale.md` records `GO` /
> `GO-WITH-WARNINGS`, and a QC `FAIL` hands off to `nanobc-debug` instead of
> declaring success. Don't skip them.

## 🧰 Tools

| Tool | Version | Role |
|:-----|:--------|:-----|
| `dorado` | **not pinned** (ONT ships a standalone GPU binary) | basecaller — invoked via `params.dorado_bin`, version recorded per-run in `params.rationale.md` |
| `samtools` / `seqtk` | pinned (`runners/nextflow-runner/envs/*/pixi.lock`) | `bam2fq` demultiplexing + `concat_fastq` per-barcode aggregation (pipeline v0.1.1); `total_bases` remains off the shipped DAG |
| `nextflow` | required by the pipeline in mode `nextflow` (≥ 25.06 for `-preview`) | workflow executor |
| `bash` + coreutils | required in mode `manual` | `run_basecalling.sh` / `demux_bam.sh` (no Nextflow needed; samtools still via the pinned pixi env) |
| `jq` | system | `params.json` reads in every sub-skill |
| `tmux` | system (local profile) | session for `track-progress.sh` (nextflow mode) |
| `nvidia-smi` / `nvidia-settings` | driver-provided | GPU health checks + optional fan helper (`preflight/nanobc-preflight/gpu-fan.sh`) |

Tool usage is grounded in the pipeline's own source (`main.nf`,
`nextflow.config`, `modules/*.nf`) and the offline `docs-corpus/` snapshots —
never from the agent's memory.

> [!NOTE]
> Dorado's version is **not pinned** by the repo; preflight is the only place
> that version gets recorded per run. The shipped SLURM `clusterOptions` are
> **placeholders** — override them per cluster via `-c` with a gitignored
> `nextflow.config.<cluster>.local` (see `preflight/nanobc-preflight` §2.5).

## 🔄 Update check

`bin/skill-update-check.py` (wired to `pixi run update-check`) diffs the
deployed git SHA against upstream via `git fetch` — no GitHub API call, no
extra dependencies:

```bash
pixi run update-check          # or: python3 bin/skill-update-check.py
```

| Verdict | Meaning |
|:--------|:--------|
| `UP-TO-DATE` (0) / `LOCAL-AHEAD` (0) | local skills are current (ahead = unpushed local commits) |
| `BEHIND-BY-N` (1) | upstream is N commits ahead → `git pull`, then `diff -rq` against any deployed copies |
| `OFFLINE` (2) / `NO-ORIGIN` (2) | informational — compare `local_sha` + `version:` by hand |

## 📁 Repository layout

```text
nanobc/                          # NANOBC_HOME — skill root = pipeline home parent
├── SKILL.md                     # router — start here
├── README.md                    # this file
├── pixi.toml                    # skill manifest (update-check task)
├── bin/skill-update-check.py    # git-SHA drift check
├── docs-corpus/<tool>/          # offline docs snapshots (dorado, samtools, seqtk, nextflow)
├── preflight/nanobc-preflight/  # Phase 1 (incl. gpu-fan.sh helper)
├── run/nanobc-run/              # Phase 2 (incl. track-progress.sh)
├── debug/nanobc-debug/          # Phase 3
├── qc/nanobc-qc/                # Phase 4
└── runners/
    ├── bash-recipes/            # manual executor + 29-check CPU-only smoke test
    └── nextflow-runner/         # nf-nanopore-basecalling pipeline (source of truth)
        ├── main.nf, nextflow.config, modules/, envs/, params/
        ├── test_pipeline_smoke.sh  # CPU-only end-to-end DAG test (fake dorado)
        └── README.md
```

## 🔒 Hard guarantees

- **Filesystem evidence chain** — every phase emits the artifact the next
  phase consumes; the boundary between phases is the filesystem, not agent
  memory.
- **Verdict gates** — preflight writes `GO` / `GO-WITH-WARNINGS` / `NO-GO`;
  QC writes `PASS` / `PASS-WITH-WARNINGS` / `FAIL`; the next phase refuses on
  a failing verdict.
- **Reasoning, not fabrication** — no invented Dorado model/kit names, no
  fabricated throughput numbers; tool flags are grounded in the pipeline's
  own source and `docs-corpus/`.
- **Explicit stop points** — ambiguous decisions are surfaced as
  *Evidence + Recommend + Options* with auto-pick rules, not silently decided.
- **Config never modified in place** — user-side overrides land in
  `nextflow.config.<env>.local` files (applied via `-c`, using `withLabel:`
  blocks); the pipeline's `nextflow.config` is never edited.
- **Pipeline/recipe lock-step** — the bash recipes mirror
  `modules/dorado.nf` + `main.nf` command-for-command; `test_smoke.sh`
  enforces the awk lock-step automatically, and any pipeline change must ship
  with a matching recipe change in the same commit.

## 🧭 Scope notes

- No assembly, no reference genome, no annotation step — QC here is about
  **run/output integrity**, not biological correctness.
- Per-process `withName:` overrides won't work — the pipeline's processes
  carry **labels** (`dorado`, `samtools`, `seqtk`, `transfer`); any user-side
  override must use `withLabel:`.
- Dorado has no conda/pixi package — it is invoked via `params.dorado_bin`,
  resolved from `$PATH` by default.
- The manual bash-recipes path has **no resume/retry**: every pod5 chunk
  re-runs on retry. For long or interruptible runs, use the Nextflow runner.
- Multi-chunk pod5 deliveries are safe: chunk ids keep every part of the
  filename except the `.pod5` marker (pipeline v0.1.1 fixed the
  publishDir-overwrite bug), and per-barcode outputs are aggregated across
  chunks by `concat_fastq`.

## Provenance

Authored and restructured following the
[skill-forge](https://github.com/cheahhl814/skill-forge) meta-skill
conventions (phased evidence chain, verdict gates, ask-user stop points,
signature libraries, bash-recipes/nextflow-runner dual path, docs-corpus,
`bin/skill-update-check.py`). Pattern sources:

- **BettaMt-agents** — https://github.com/cheahhl814/BettaMt-agents
- **bacterial-genome-analysis** (v5.x layout reference) — https://github.com/cheahhl814/bacterial-genome-analysis
- **amr-gene-screening** — https://github.com/cheahhl814/amr-gene-screening
- **nf-skill** — https://github.com/cheahhl814/nf-skill (DSL2 + nf-core conventions)