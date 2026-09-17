# nf-nanopore-basecalling agentic skills

[![Version](https://img.shields.io/badge/version-1.1.0-blue)](#-installation)
[![Type](https://img.shields.io/badge/type-agent%20skill-blueviolet)](#-installation)
[![Built with](https://img.shields.io/badge/built%20with-bioinfo--skill--creator-orange)](https://github.com/cheahhl814/bioinfo-skill-creator)
[![Shape](https://img.shields.io/badge/shape-multi--tool%20pipeline-8A2BE2)](#-pipeline-overview)

Agentic companion skills for the `nf-nanopore-basecalling` Nextflow pipeline (Dorado basecalling → optional demultiplexing → base-count QC). Four sibling skills — `nanobc-run` (orchestrator), `nanobc-preflight` (parameter/GPU/cluster preparation), `nanobc-debug` (failure interpretation), `nanobc-qc` (output integrity QC) — form a **filesystem evidence chain**: each phase writes the artifacts the next phase consumes and gates progression with an explicit verdict. The pipeline itself is untouched; the skills consume its inputs and outputs.

**Repository**: https://github.com/cheahhl814/nanobc

> [!NOTE]
> Current version: **v1.1.0** (updated 2026-09-17).

## Contents

- [Installation](#-installation)
- [Usage](#-usage)
- [Pipeline overview](#-pipeline-overview)
- [Tools](#-tools)
- [Update check](#-update-check)
- [Repository layout](#-repository-layout)
- [Relocating](#-relocating)
- [Hard guarantees](#-hard-guarantees)
- [Extending](#-extending)
- [What this bundle does NOT have](#-what-this-bundle-does-not-have)
- [Provenance](#provenance)

## 🚀 Installation

This is an **agent skill** bundle, not a user-facing library. The recommended install path is to let your AI agent import it.

**Option A — give your agent this prompt (recommended):**

```text
Install the nanobc agentic skills from https://github.com/cheahhl814/nanobc —
make the four .agents/skills/nanobc-* directories visible in your agent's
skills directory (the path your agent watches for skills — symlink the
sibling-skill bundle or each skill individually). Then read each SKILL.md
to understand its phases and the Input/Output contract for each. Confirm
when the environment is ready.
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

> [!TIP]
> The skills directory on this bundle lives at `.agents/skills/` (with the `s`) — the cross-tool Agent Skills standard convention, auto-scanned from `cwd` up to the repo root by `pi`, OpenCode, and Codex (see [Relocating](#-relocating)).

## 💡 Usage

The bundle is designed to be driven by an AI agent. `nanobc-run` is the recommended entry point: it detects the current stage from the filesystem state of your run directory and routes to the right skill.

### Natural-language prompts that trigger the bundle

```text
Run the basecalling pipeline / basecall this pod5 folder     → nanobc-run
Set up nanopore basecalling / which dorado model            → nanobc-preflight
Fix slurm partition dorado / check gpu before running       → nanobc-preflight
Basecalling failed / why did the pipeline fail / gpu throttling → nanobc-debug
Check basecalling output / did the demux work / check the demux fastqs → nanobc-qc
```

### Manual phase execution

Each skill is independently triggerable — set a run directory (all phase artifacts land there) and invoke the one you need:

```bash
RUN_DIR=/path/to/run-dir          # one per sample / pod5 batch

nanobc-preflight   # Phase 1 — validate pod5/model/kit/GPU/cluster, write params.json + params.rationale.md
nanobc-run         # Phase 2 — execute nextflow run (after preflight verdict ≥ GO-WITH-WARNINGS)
nanobc-qc          # Phase 3 — check output integrity, write report.md (after the run finishes)
nanobc-debug       # On failure — interpret the run via the signature library, write diagnosis.md
```

> [!IMPORTANT]
> Each skill has an explicit **Inputs / Outputs contract** at the top of its `SKILL.md`, and phases are **verdict-gated**: `nanobc-run` refuses to execute `nextflow run` unless `params.rationale.md` records `GO` / `GO-WITH-WARNINGS`, and a QC `FAIL` hands off to `nanobc-debug` instead of declaring success. Don't skip them.

## 🔬 Pipeline overview

The agentic layer follows a phased evidence chain. Each phase consumes the artifacts of the previous phase and gates progression — the boundary between phases is the **filesystem**, not agent memory.

| # | Phase | Goal | Skill | Artifact produced |
|:--|:------|:-----|:------|:------------------|
| **1** | **Preflight** | Validate pod5/model/kit/GPU/cluster, write params | `nanobc-preflight` | `$RUN_DIR/params.json` + `params.rationale.md` (+ optional `nextflow.config.<env>.local`) |
| **2** | **Run** | Execute `nextflow run` with the params | `nanobc-run` | FASTQs under `$OUTDIR` (`dorado_basecall_lsk/` or `fastq/` incl. `unknown`; optional `$RUN_DIR/progress.log` via `track-progress.sh`) |
| **3** | **Debug** | Interpret a failed run | `nanobc-debug` | `$RUN_DIR/diagnosis.md` (top-3 ranked hypotheses + Option A/B fixes) |
| **4** | **QC** | Check output integrity + base/read counts | `nanobc-qc` | `$RUN_DIR/report.md` (overall PASS / PASS-WITH-WARNINGS / FAIL) |

> [!TIP]
> Read each skill's `SKILL.md` for the full procedure, its ask-user stop points (SP tables — *Evidence + Recommend + Options*), and its troubleshooting signature library (stderr pattern → cause → fix).

## 🧰 Tools

All conda-installable tools are pinned via pixi manifests in the **pipeline** repo (`nf-nanopore-basecalling/envs/<tool>/pixi.toml`); the skills bundle itself ships no environment of its own.

| Tool | Version | Role |
|:-----|:--------|:-----|
| `dorado` | **not pinned** (ONT ships a standalone GPU binary) | basecaller — invoked via `params.dorado_bin`, version recorded per-run in `params.rationale.md` |
| `samtools` / `seqtk` | pinned (`envs/*/pixi.lock`) | `bam2fq` demultiplexing (`concat_fastq`/`total_bases` modules exist but are no longer on the shipped DAG) |
| `nextflow` | required by the pipeline (≥ 25.06 for `-preview`) | workflow executor |
| `jq` | system | `params.json` reads in every skill |
| `tmux` | system (local profile) | session for `track-progress.sh` |
| `nvidia-smi` / `nvidia-settings` | driver-provided | GPU health checks (§2e) + optional fan helper `gpu-fan.sh` |

Tool usage is grounded in the pipeline's own source (`main.nf`, `nextflow.config`, `modules/*.nf` — line references quoted in the skills) and recorded `--version` outputs — never from the agent's memory. This bundle ships no offline `docs-corpus/` snapshot; where the generated-skill convention would use one, the skills cite the pinned pipeline source instead.

## 🔄 Update check

This bundle does **not** ship `bin/skill-update-check.py` (the skills live inside the `nanobc` repo rather than as a standalone published skill). To check for drift, use plain git once an `origin` remote is configured:

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
nanobc/                         # this repo (local checkout dir can be anything)
├── README.md                     # This file (bundle-level)
└── .agents/skills/
    ├── README.md                 # This file's source location
    ├── nanobc-run/               # Orchestrator (router — start here)
    │   ├── SKILL.md
    │   └── track-progress.sh     # Optional background progress logger
    ├── nanobc-preflight/         # Phase 1 — params + GPU/cluster evidence
    │   ├── SKILL.md
    │   └── gpu-fan.sh            # Optional GPU fan helper (local workstation)
    ├── nanobc-debug/             # Failure interpreter
    │   └── SKILL.md
    └── nanobc-qc/                # Post-run QC
        └── SKILL.md
```

The four skills share one principle: **the agent reasons; the pipeline executes**.

## 📦 Relocating

This folder is meant to live one directory level above the `nf-nanopore-basecalling/` pipeline directory, so the pipeline's working tree stays clean and shippable on its own. Each skill resolves `NANOBC_HOME` in this order:

1. `$NANOBC_HOME` env var (set by user)
2. Sibling directory `../nf-nanopore-basecalling` next to this skill folder
3. Asks the user

```text
Nextflow/
├── nanobc/                        # this repo
│   └── .agents/skills/           # skills folder
│       ├── nanobc-run/           # entry point — start here
│       ├── nanobc-preflight/
│       ├── nanobc-debug/
│       └── nanobc-qc/
└── nf-nanopore-basecalling/       # pipeline (clean, shippable, its own git repo)
```

**Why `.agents/` (with the `s`)?** This is the cross-tool Agent Skills standard convention. `pi`, OpenCode, and Codex all auto-scan `.agents/skills/` from `cwd` up to the repo root. The singular `.agent/` is silently ignored by all of them. Claude Code is the one exception — it scans `.claude/skills/`; see anthropics/claude-code#33733.

## 🔒 Hard guarantees

- **Filesystem evidence chain** — every phase emits the artifact the next phase consumes; the boundary between phases is the filesystem, not agent memory.
- **Verdict gates** — preflight writes an overall `GO` / `GO-WITH-WARNINGS` / `NO-GO` verdict; QC writes `PASS` / `PASS-WITH-WARNINGS` / `FAIL`; the next phase refuses on a failing verdict.
- **Reasoning, not fabrication** — no invented Dorado model/kit names, no fabricated throughput numbers; tool flags are grounded in the pipeline's own source, and Dorado's unpinned version is recorded per-run in `params.rationale.md`.
- **Explicit stop points** — ambiguous decisions are surfaced as *Evidence + Recommend + Options* with auto-pick rules, not silently decided.
- **Config never modified in place** — user-side overrides land in `nextflow.config.<env>.local` files (applied via `-c`, using `withLabel:` blocks); the pipeline's `nextflow.config` is never edited.

## 📦 Extending

When you encounter a new failure mode, add a row to the signature table in `nanobc-debug/SKILL.md` (§2) rather than writing a script. When you discover a new QC concern, add a check section to `nanobc-qc/SKILL.md`. The skill files are versioned alongside the pipeline (or separately, as you prefer).

## 🧭 What this bundle does NOT have

- No assembly, no reference genome, no annotation step — QC here is about **run/output integrity** (did basecalling and demultiplexing produce sane, complete, non-corrupt FASTQ), not biological correctness.
- No per-process `withName:` overrides — `nextflow.config` here uses **labels** (`dorado`, `samtools`, `seqtk`, `transfer`), so any user-side override must use `withLabel:`, not `withName:`.
- Dorado itself has no conda/pixi package (ONT ships it as a standalone GPU binary) — it is invoked via `params.dorado_bin`, resolved from `$PATH` by default. Its version is **not** pinned by the repo; the preflight/rationale step is the only place that version gets recorded per run.
- No `pixi.toml` / `bin/skill-update-check.py` of its own (unlike skills generated by bioinfo-skill-creator) — the tool environment is pinned in the pipeline repo's `envs/`, and drift detection is plain git ([Update check](#-update-check)).

## Provenance

Authored following the [bioinfo-skill-creator](https://github.com/cheahhl814/bioinfo-skill-creator) meta-skill conventions (v1.3.0 templates: `SUB_SKILL_SKILL.md.j2`, `ORCHESTRATOR_SKILL.md.j2`, `README.md.j2`) — phased evidence chain, verdict gates, ask-user stop points, and signature libraries. Pattern adopted from:

- **BettaMt-agents** — https://github.com/cheahhl814/BettaMt-agents
- **bacterial-genome-analysis** — https://github.com/cheahhl814/bacterial-genome-analysis
- **amr-gene-screening** — https://github.com/cheahhl814/amr-gene-screening