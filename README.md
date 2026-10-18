# nanobc

[![Version](https://img.shields.io/badge/version-1.2.1-blue)](#-installation)
[![Built with](https://img.shields.io/badge/built%20with-bioinfo--skill--creator-orange)](https://github.com/cheahhl814/bioinfo-skill-creator)
[![Shape](https://img.shields.io/badge/shape-multi--tool%20pipeline-8A2BE2)](#-pipeline-overview)

A Nextflow (DSL2) pipeline for Dorado-based Nanopore basecalling → optional
barcode demultiplexing → output QC, paired with a four-skill agentic layer —
`nanobc-run` (orchestrator), `nanobc-preflight` (params + GPU/cluster
evidence), `nanobc-debug` (failure interpretation), `nanobc-qc` (output
integrity) — that forms a **filesystem evidence chain** around the pipeline:
each phase writes the artifacts the next phase consumes and gates progression
with an explicit verdict.

**Repository**: https://github.com/cheahhl814/nanobc

> [!NOTE]
> Skills **v1.2.1** · pipeline **v0.1.1** (updated 2026-10-18).
>
> v1.2.1 fixes multi-chunk publishDir overwrites (pipeline v0.1.1: collision-proof chunk ids, barcoded per-barcode aggregation) and adds the **manual bash-recipes path** (`nf-nanopore-basecalling/runners/bash-recipes/`): every run now pins an execution mode — Nextflow runner (HPC/cluster/cohort) or manual bash recipes (single-machine, no-Nextflow) — recorded in `params.json:execution_mode` at preflight.

## Contents

- [Installation](#-installation)
- [Usage](#-usage)
- [Pipeline overview](#-pipeline-overview)
- [Tools](#-tools)
- [Update check](#-update-check)
- [Repository layout](#-repository-layout)
- [Relocating](#-relocating)
- [Hard guarantees](#-hard-guarantees)
- [Scope notes](#-scope-notes)
- [Provenance](#provenance)

## 🚀 Installation

**Option A — give your agent this prompt (recommended):**

```text
Install the nanobc agentic skills from https://github.com/cheahhl814/nanobc —
clone it, make the four .agents/skills/nanobc-* directories visible in your
agent's skills directory (the path your agent watches for skills — symlink
each skill individually). Then read each SKILL.md to understand its phases
and the Input/Output contract for each. Confirm when the environment is ready.
```

**Option B — manual install (per user):**

```bash
git clone https://github.com/cheahhl814/nanobc.git
# From the checkout, symlink each skill into your agent's skills directory:
ln -s "$(pwd)/.agents/skills/nanobc-run"        <your-agents-skills-dir>/
ln -s "$(pwd)/.agents/skills/nanobc-preflight"  <your-agents-skills-dir>/
ln -s "$(pwd)/.agents/skills/nanobc-debug"      <your-agents-skills-dir>/
ln -s "$(pwd)/.agents/skills/nanobc-qc"         <your-agents-skills-dir>/
```

**Pipeline runtime** (needed wherever the run actually executes):

- [Nextflow](https://www.nextflow.io/) >= 23.04 (>= 25.06 if you want the
  `-preview` dry-run flag — on older versions it is spelled `-dry-run`) —
  needed in mode `nextflow` only
- [Dorado](https://github.com/nanoporetech/dorado) — a standalone GPU binary
  from ONT; put it on `$PATH` or point `--dorado_bin` at it. A CUDA-capable
  GPU is required for basecalling in **both modes**.
- [pixi](https://pixi.sh/) — `samtools`/`seqtk` resolve through pinned
  environments on demand (`pixi run --manifest-path envs/<tool>/pixi.toml ...`
  from inside each process, and on the manual path inside `demux_bam.sh`); no
  manual install of these tools is needed.

> [!TIP]
> The skills directory lives at `.agents/skills/` (with the `s`) — the
> cross-tool Agent Skills standard convention, auto-scanned from `cwd` up to
> the repo root by `pi`, OpenCode, and Codex. The singular `.agent/` is
> silently ignored by all of them (Claude Code is the one exception — it scans
> `.claude/skills/`; see anthropics/claude-code#33733).

> [!IMPORTANT]
> Each skill has an explicit **Inputs / Outputs contract** at the top of its
> `SKILL.md`, and phases are **verdict-gated**: `nanobc-run` refuses to execute
> `nextflow run` unless `params.rationale.md` records `GO` /
> `GO-WITH-WARNINGS`, and a QC `FAIL` hands off to `nanobc-debug` instead of
> declaring success. Don't skip them.

## 💡 Usage

The bundle is designed to be driven by an AI agent: `nanobc-run` is the
recommended entry point — it detects the current stage from the filesystem
state of your run directory and routes to the right skill.

### Quick start — pipeline

**Nextflow runner** (HPC/SLURM, cohort, trace/report/timeline artifacts):

```bash
cd nf-nanopore-basecalling
nextflow run main.nf -profile slurm \
  --pod5   "input_folder/N046/*.pod5" \
  --model  /path/to/dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
  --kitname SQK-LSK114
```

**Manual bash recipes** (single machine, no Nextflow required — still needs the CUDA GPU + dorado + model):

```bash
./nf-nanopore-basecalling/runners/bash-recipes/run_basecalling.sh \
  --pod5   "input_folder/N046/*.pod5" \
  --model  /path/to/dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
  --kitname SQK-LSK114 --outdir ./results/N046

# validate the recipes first on any CPU-only machine (no GPU/dorado/model needed):
./nf-nanopore-basecalling/runners/bash-recipes/test_smoke.sh
```

`--pod5` and `--model` are required in both modes; execution aborts early without them. See
[`nf-nanopore-basecalling/README.md`](nf-nanopore-basecalling/README.md) for the full parameter table
and [`runners/bash-recipes/README.md`](nf-nanopore-basecalling/runners/bash-recipes/README.md) for the
two-mode trade-off table.

### Natural-language prompts that trigger the bundle

```text
Run the basecalling pipeline / basecall this pod5 folder      → nanobc-run
Set up nanopore basecalling / which dorado model              → nanobc-preflight
Fix slurm partition dorado / check gpu before running         → nanobc-preflight
Basecalling failed / why did the pipeline fail / gpu throttling → nanobc-debug
Check basecalling output / did the demux work                 → nanobc-qc
```

### Manual phase execution

If you prefer to drive the phases yourself (or re-run a single phase), set a
run directory — all phase artifacts land there — and invoke the skill you need:

```bash
RUN_DIR=/path/to/run-dir          # one per sample / pod5 batch

nanobc-preflight   # Phase 1 — validate pod5/model/kit/GPU/cluster, write params.json + params.rationale.md
nanobc-run         # Phase 2 — execute the run, mode from params.json:execution_mode (after preflight verdict ≥ GO-WITH-WARNINGS)
nanobc-qc          # Phase 3 — check output integrity, write report.md (after the run finishes)
nanobc-debug       # On failure — interpret the run via the signature library, write diagnosis.md
```

Each run also writes an execution trace, HTML report, and timeline under
`<outdir>/pipeline_info/`.

## 🔬 Pipeline overview

The agentic layer follows a phased evidence chain. Each phase consumes the
artifacts of the previous phase and gates progression — the boundary between
phases is the **filesystem**, not agent memory.

| # | Phase | Goal | Skill | Artifact produced |
|:--|:------|:-----|:------|:------------------|
| **1** | **Preflight** | Validate pod5/model/kit/GPU/cluster + execution mode, write params | `nanobc-preflight` | `$RUN_DIR/params.json` (incl. `execution_mode`) + `params.rationale.md` (+ optional `nextflow.config.<env>.local`) |
| **2** | **Run** | Execute the run, mode from `params.json:execution_mode` | `nanobc-run` | FASTQs under `$OUTDIR` (identical layouts in both modes) |
| **3** | **Debug** | Interpret a failed run | `nanobc-debug` | `$RUN_DIR/diagnosis.md` (top-3 ranked hypotheses + Option A/B fixes) |
| **4** | **QC** | Check output integrity + read counts | `nanobc-qc` | `$RUN_DIR/report.md` (overall PASS / PASS-WITH-WARNINGS / FAIL) |

Two paths through the pipeline, selected by `--kitname`:

- **LSK kits** (e.g. `SQK-LSK114`): `dorado_basecall_lsk` emits FASTQ directly;
  optionally rsynced to a remote destination via `--transfer_dest`.
- **Barcoded kits** (e.g. `SQK-RBK114`): `dorado_basecall` emits a BAM, which
  is demultiplexed per barcode (`bam2fq`, per-chunk files named
  `<chunk-id>_<barcode>.fastq.gz`), then `concat_fastq` aggregates each
  barcode across chunks — a single `<barcode>.fastq.gz` per barcode is
  published to `<outdir>/fastq/` (incl. `unknown.fastq.gz`).

> [!TIP]
> Read each skill's `SKILL.md` for the full procedure, its ask-user stop points
> (SP tables — *Evidence + Recommend + Options*), and its troubleshooting
> signature library (stderr pattern → cause → fix).

## 🧰 Tools

All conda-installable tools are pinned via pixi manifests in the pipeline
(`nf-nanopore-basecalling/envs/<tool>/pixi.toml` + `pixi.lock`); the skills
bundle itself ships no environment of its own.

| Tool | Version | Role |
|:-----|:--------|:-----|
| `dorado` | **not pinned** (ONT ships a standalone GPU binary) | basecaller — invoked via `params.dorado_bin`, version recorded per-run in `params.rationale.md` |
| `samtools` / `seqtk` | pinned (`envs/*/pixi.lock`) | `bam2fq` demultiplexing + `concat_fastq` per-barcode aggregation (pipeline v0.1.1) |
| `nextflow` | required by the pipeline (≥ 25.06 for `-preview`) | workflow executor |
| `jq` | system | `params.json` reads in every skill |
| `tmux` | system (local profile) | session for `track-progress.sh` |
| `nvidia-smi` / `nvidia-settings` | driver-provided | GPU health checks + optional fan helper (`gpu-fan.sh`) |

Tool usage is grounded in the pipeline's own source (`main.nf`,
`nextflow.config`, `modules/*.nf` — line references quoted in the skills) and
recorded `--version` outputs — never from the agent's memory.

> [!NOTE]
> The `local` profile targets a CUDA-capable workstation GPU with large VRAM.
> Card-specific runbook notes (OOM likelihood, thermal-throttling checks under
> Dorado's sustained load, and why the shipped SLURM `clusterOptions` are
> placeholders that may not match your cluster) live in `nanobc-preflight`
> §2e.1 and `nanobc-debug` §1.6.

## 🔄 Update check

This repo does **not** ship `bin/skill-update-check.py` (the skills live inside
the `nanobc` repo rather than as a standalone published skill). To check for
drift, use plain git:

```bash
git fetch origin
git rev-list HEAD..origin/main -- .agents/skills/   # non-empty → upstream skills moved; re-pull
```

| Verdict | Meaning |
|:--------|:--------|
| empty `rev-list` output | Local skills are current |
| N commits listed | Upstream is N commits ahead → `git pull`, then `diff -rq` against any deployed copies |

## 📁 Repository layout

```text
nanobc/
├── README.md                     # This file
├── .gitignore
├── .agents/skills/
│   ├── README.md                 # Skills-bundle README (deeper detail)
│   ├── nanobc-run/               # Orchestrator + execution-mode fork (router — start here)
│   │   ├── SKILL.md
│   │   └── track-progress.sh     # Optional background progress logger (nextflow mode)
│   ├── nanobc-preflight/         # Phase 1 — params + GPU/cluster/execution-mode evidence
│   │   ├── SKILL.md
│   │   └── gpu-fan.sh            # Optional GPU fan helper (local workstation)
│   ├── nanobc-debug/             # Failure interpreter (both modes)
│   │   └── SKILL.md
│   └── nanobc-qc/                # Post-run QC (mode-agnostic)
│       └── SKILL.md
└── nf-nanopore-basecalling/      # The pipeline (clean, shippable, its own tree)
    ├── main.nf
    ├── nextflow.config
    ├── modules/dorado.nf
    ├── params/example.json
    ├── envs/samtools/{pixi.toml,pixi.lock}
    ├── envs/seqtk/{pixi.toml,pixi.lock}
    ├── runners/
    │   └── bash-recipes/         # v1.2.1 — manual execution path
    │       ├── run_basecalling.sh      # driver: LSK + barcoded paths, optional transfer
    │       ├── demux_bam.sh            # bam2fq equivalent (samtools pixi env + awk BC:Z)
    │       ├── test_smoke.sh           # CPU-only smoke test (no GPU/dorado/model needed)
    │       └── README.md               # two-mode trade-off table + divergence rule
    └── README.md                 # Pipeline parameter table, profiles, output layout
```

Each skill resolves the pipeline home (`NANOBC_HOME`) in this order:

1. `$NANOBC_HOME` env var (set by user)
2. Sibling directory `../nf-nanopore-basecalling` next to the skill's parent
3. Asks the user

## 📦 Relocating

This repo is meant to live one directory level above the
`nf-nanopore-basecalling/` pipeline directory, so the pipeline's working tree
stays clean and shippable on its own:

```text
Nextflow/
├── nanobc/                        # this repo
│   └── .agents/skills/
└── nf-nanopore-basecalling/       # pipeline
```

**Why `.agents/` (with the `s`)?** The cross-tool Agent Skills standard
convention — `pi`, OpenCode, and Codex all auto-scan `.agents/skills/` from
`cwd` up to the repo root. The singular `.agent/` is silently ignored by all
of them. Claude Code is the one exception — it scans `.claude/skills/`; see
anthropics/claude-code#33733.

To install the skills globally for one user, symlink them into your agent's
skills directory (see [Installation](#-installation)).

## 🔒 Hard guarantees

- **Filesystem evidence chain** — every phase emits the artifact the next
  phase consumes; the boundary between phases is the filesystem, not agent
  memory.
- **Verdict gates** — preflight writes an overall `GO` / `GO-WITH-WARNINGS` /
  `NO-GO` verdict; QC writes `PASS` / `PASS-WITH-WARNINGS` / `FAIL`; the next
  phase refuses on a failing verdict.
- **Reasoning, not fabrication** — no invented Dorado model/kit names, no
  fabricated throughput numbers; tool flags are grounded in the pipeline's own
  source, and Dorado's unpinned version is recorded per-run in
  `params.rationale.md`.
- **Explicit stop points** — ambiguous decisions are surfaced as
  *Evidence + Recommend + Options* with auto-pick rules, not silently decided.
- **Config never modified in place** — user-side overrides land in
  `nextflow.config.<env>.local` files (applied via `-c`, using `withLabel:`
  blocks); the pipeline's `nextflow.config` is never edited.

## 🧭 Scope notes

- No assembly, no reference genome, no annotation step — QC here is about
  **run/output integrity** (did basecalling and demultiplexing produce sane,
  complete, non-corrupt FASTQ), not biological correctness.
- Per-process `withName:` overrides won't work here — the pipeline's processes
  carry **labels** (`dorado`, `samtools`, `seqtk`, `transfer`), so any
  user-side override must use `withLabel:`.
- Dorado has no conda/pixi package (ONT ships it as a standalone GPU binary) —
  it is invoked via `params.dorado_bin`, resolved from `$PATH` by default. Its
  version is **not** pinned by the repo; the preflight step is the only place
  that version gets recorded per run.
- The shipped SLURM `clusterOptions` are **placeholders** — override them per
  cluster via `-c` with a gitignored `nextflow.config.<cluster>.local` (see
  `nanobc-preflight` §2.5c/d).

## Provenance

Authored following the
[bioinfo-skill-creator](https://github.com/cheahhl814/bioinfo-skill-creator)
meta-skill conventions (v1.3.0 templates — phased evidence chain, verdict
gates, ask-user stop points, signature libraries). Pattern adopted from:

- **BettaMt-agents** — https://github.com/cheahhl814/BettaMt-agents
- **bacterial-genome-analysis** — https://github.com/cheahhl814/bacterial-genome-analysis
- **amr-gene-screening** — https://github.com/cheahhl814/amr-gene-screening