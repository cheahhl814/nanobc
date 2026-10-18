---
name: nanobc
description: 'Dorado-based Nanopore basecalling agent skill: preflight → run → qc, with a signature-library debug phase, over a dual execution path (Nextflow DSL2 runner for HPC/cohort; manual bash recipes for single-machine/no-Nextflow) and a CPU-only smoke-test harness. Use when the user wants to basecall pod5 files, pick a Dorado model/kit, check GPU health, verify a demultiplexed FASTQ output, or fix a failed basecalling run. Triggers: "basecall pod5", "nanopore basecalling", "dorado model", "run basecalling pipeline", "basecalling failed", "check demux fastqs".'
version: 2.0.0
updated: "2026-10-18"
triggers:
  - "run the basecalling pipeline"
  - "basecall this pod5 folder"
  - "I have pod5 files"
  - "nanobc"
  - "nanobc run"
  - "dorado pipeline"
  - "set up nanopore basecalling"
  - "which dorado model"
  - "basecalling failed"
  - "check basecalling output"
  - "check demux fastqs"
  - "gpu throttling dorado"
---

# Meta-Skill: nanobc

> **v2.0.0 — restructured to the [skill-forge](https://github.com/cheahhl814/skill-forge)
> layout.** The pipeline now lives at `runners/nextflow-runner/`, the four phase
> sub-skills at `preflight/`, `run/`, `debug/`, `qc/` (one named sub-skill each),
> the manual executor at `runners/bash-recipes/`, plus a CPU-only test harness at
> `runners/nextflow-runner/test_pipeline_smoke.sh`, a skill-level `pixi.toml`,
> `bin/skill-update-check.py`, and a `docs-corpus/`. Predecessors: v1.2.x
> (dual-path bundle with skills under `.agents/skills/` and the pipeline as a
> sibling tree) and v1.1 (nextflow-centric).
>
> **v1.2.x capabilities retained**: the bash-vs-Nextflow execution-mode fork with
> `params.json:execution_mode` pinned by preflight, the multi-chunk
> publishDir-overwrite fix (`pod5Id()` + per-barcode `concat_fastq`
> aggregation — pipeline v0.1.1), and the verdict-gated evidence chain.

**This SKILL.md is a router.** It detects the user's phase from filesystem
evidence and routes to the sub-skill that executes it. The sub-skills own all
artifacts; this file produces none.

## Audience

Two audiences:

1. **AI Coding Agents** — triggered by the phrases above. Detect the stage from
   filesystem evidence **before** asking, route to the right sub-skill, honour
   its verdict gates, and hand off explicitly.
2. **Human Users** — a predictable entry point that always answers "which phase
   runs next, and what artifact will it produce?"

## When to Use This Skill

Basecalling/Demux/QC of Nanopore pod5 data with Dorado, on a workstation or
SLURM cluster:

- basecall a pod5 folder → `run/nanobc-run`
- decide kit/model/dorado binary, validate GPU health, pin the execution mode → `preflight/nanobc-preflight`
- a run failed, or output looks wrong (empty/`unknown`-dominated FASTQ) → `debug/nanobc-debug`
- a run finished and output integrity matters → `qc/nanobc-qc`

Do NOT use when the user has already basecalled FASTQs and only needs
downstream assembly / alignment — this skill ends at demultiplexed FASTQ
integrity QC; it has no assembly/annotation step.

## 0. Orchestrator — detect phase, route to the right sub-skill

### 0.1 Locate the skill and the pipeline

```bash
# NANOBC_HOME = this skill's checkout root. The Nextflow pipeline lives at
# $NANOBC_HOME/runners/nextflow-runner; the manual bash recipes at
# $NANOBC_HOME/runners/bash-recipes.
: "${NANOBC_HOME:=$(pwd)}"

test -f "$NANOBC_HOME/SKILL.md" \
  || { echo "$NANOBC_HOME does not look like the nanobc skill root. Set NANOBC_HOME."; exit 1; }
```

### 0.2 Phase detection ladder — first match wins

```bash
# Artifacts live in $RUN_DIR (one per sample / pod5 batch; default = pipeline outdir parent)
test -f "$RUN_DIR/report.md"            && PHASE="qc-done"        # QC verdict written
ls  "$OUTDIR"/fastq/*.fastq.gz >/dev/null 2>&1                && PHASE="qc"
ls  "$OUTDIR"/dorado_basecall_lsk/*.fastq.gz >/dev/null 2>&1  && PHASE="qc"
test -f "$RUN_DIR/diagnosis.md"         && PHASE="review-diagnosis"
test -f "$RUN_DIR/params.json"          && PHASE="run"
: "${PHASE:=preflight}"
```

`params.json:execution_mode` (`"nextflow"` | `"manual"`, written by
`nanobc-preflight` SP6) selects the execution path of the `run` phase; see
**§0.4**.

### 0.3 Ask-user stop points

This orchestrator has **one** user-facing stop point; all others live in the
sub-skills (`nanobc-preflight` SP1–SP6, `nanobc-run` SP0–SP2+SP1a,
`nanobc-debug` SP1–SP3, `nanobc-qc` §0.5). The pattern is **Evidence +
Recommend + Options**; auto-pick when the evidence is unambiguous.

#### SP0 — Entry-phase ambiguity

| Trigger | Ask |
| --- | --- |
| Ladder returns `preflight` but the user clearly wants something else, or `params.json` exists with no run history (no outputs, no logs) | "Are you starting a new run, continuing one, or debugging a failure?" |

**Auto-pick when**: the evidence is unambiguous (fresh run dir → `preflight`;
outputs present → `qc`; failure signature quoted → `debug`).

### 0.3.1 Route to the right sub-skill

| Phase | Sub-skill | Artifact it produces |
| --- | --- | --- |
| `preflight` | `preflight/nanobc-preflight` | `$RUN_DIR/params.json` (incl. `execution_mode`) + `params.rationale.md` (+ optional `nextflow.config.<env>.local`) |
| `run` | `run/nanobc-run` | FASTQs under `$OUTDIR` in the layout **identical** across both execution modes |
| `debug` | `debug/nanobc-debug` | `$RUN_DIR/diagnosis.md` (failed processes + top-3 ranked hypotheses + Option A/B fixes) |
| `qc` | `qc/nanobc-qc` | `$RUN_DIR/report.md` (overall PASS / PASS-WITH-WARNINGS / FAIL) |
| `review-diagnosis` | read `$RUN_DIR/diagnosis.md` with the user, execute its "Recommended next action" | — |

Do **not skip preflight** — it is the only place Dorado's unpinned version and
the kit/model routing get validated and recorded. Do **not skip QC** — the
evidence chain's final verdict gate lives there.

### 0.4 The execution-mode fork

| Mode | When | Where |
| --- | --- | --- |
| **Nextflow runner** | SLURM/cluster, cohort runs, `-resume` caching, trace/report/timeline artifacts | `runners/nextflow-runner/main.nf` |
| **Manual bash recipes** | single workstation, quick 1–2 chunk runs, no-Nextflow environments, isolated step debugging | `runners/bash-recipes/run_basecalling.sh` |

Both modes publish **identical layouts** (LSK: `$OUTDIR/dorado_basecall_lsk/`;
barcoded: `$OUTDIR/fastq/` incl. `unknown`). The Nextflow pipeline is the
source of truth (`pod5Id()` ids, chunk-id-prefixed demux, per-barcode
`concat_fastq` aggregation — v0.1.1); the recipes are command-for-command
mirrors locked by `runners/bash-recipes/test_smoke.sh`. The manual path has
**no resume** — prefer the runner for long/interruptible runs.

### 0.5 CPU-only verification (no GPU required)

`runners/nextflow-runner/test_pipeline_smoke.sh` and
`runners/bash-recipes/test_smoke.sh` run the **real** pipeline and recipes with
a deterministic fake-dorado stub — no GPU, no dorado binary, no model. Run them
after any pipeline or recipe change; a green run plus this router's structural
gate is the battle-test baseline in GPU-less environments.

## A. The evidence chain

| # | Phase | Goal | Sub-skill | Artifact |
|:--|:------|:-----|:----------|:---------|
| 1 | **Preflight** | Validate pod5/model/kit/GPU/cluster + pin execution mode | `preflight/nanobc-preflight` | `params.json` + `params.rationale.md` |
| 2 | **Run** | Execute the run in the pinned mode | `run/nanobc-run` | FASTQs under `$OUTDIR`; logs (`$OUTDIR/logging/manual_run_*.log` or `.nextflow.log`) |
| 3 | **Debug** | Interpret a failure | `debug/nanobc-debug` | `diagnosis.md` (verdict RECOVERABLE / BLOCKED) |
| 4 | **QC** | Output integrity + per-barcode read counts | `qc/nanobc-qc` | `report.md` (PASS / PASS-WITH-WARNINGS / FAIL) |

The boundary between phases is the **filesystem**, not agent memory. Every
sub-skill has an Inputs/Outputs contract at its top; a failing verdict stops
the chain.

## B. Go/No-Go gates

- **Preflight `NO-GO`** (e.g. GPU unusable on `local`, model missing for real
  runs) — do **not** run; fix and re-run preflight.
- **QC `FAIL`** — do not declare success; hand off to `debug/nanobc-debug`.
- **No GPU / no model** — neither execution mode can basecall; the CPU-only
  smoke tests are the maximum verifiable ceiling. Say so instead of guessing.
- **Ambiguous stage** — ask SP0 before routing, never guess.

## C. Output contract — no artifact (orchestrator)

This router produces no file of its own. All artifacts (`params.json`,
`params.rationale.md`, `diagnosis.md`, `report.md`) are produced by the
sub-skills.

## D. Layout

```text
nanobc/                          # NANOBC_HOME — this skill's checkout root
├── SKILL.md                     # this router
├── README.md                    # human-facing guide
├── pixi.toml                    # skill manifest (update-check task)
├── bin/skill-update-check.py    # git-SHA drift check vs github.com/cheahhl814/nanobc
├── docs-corpus/<tool>/          # offline docs snapshots (dorado, samtools, seqtk, nextflow)
├── preflight/nanobc-preflight/  # Phase 1 — params + GPU/cluster/execution-mode evidence
│   ├── SKILL.md
│   └── gpu-fan.sh               # optional GPU fan helper (local workstation)
├── run/nanobc-run/              # Phase 2 — orchestrator + execution-mode fork (entry point)
│   ├── SKILL.md
│   └── track-progress.sh        # optional background progress logger (nextflow mode)
├── debug/nanobc-debug/          # Phase 3 — failure interpreter (both modes)
│   └── SKILL.md
├── qc/nanobc-qc/                # Phase 4 — post-run QC (mode-agnostic)
│   └── SKILL.md
└── runners/
    ├── bash-recipes/            # manual executor + CPU-only smoke test
    │   ├── run_basecalling.sh   #   driver: LSK + barcoded paths, optional transfer
    │   ├── demux_bam.sh         #   bam2fq equivalent
    │   ├── test_smoke.sh        #   29-check CPU-only suite
    │   └── README.md
    └── nextflow-runner/         # the nf-nanopore-basecalling pipeline (source of truth)
        ├── main.nf, nextflow.config, modules/, envs/, params/
        ├── test_pipeline_smoke.sh  # CPU-only end-to-end DAG test (fake dorado)
        └── README.md
```

Sub-skill path resolution: `$NANOBC_HOME` env var, or the skill root above the
sub-skill dir (`$SKILL_DIR/../..`). The pipeline resolves to
`$NANOBC_HOME/runners/nextflow-runner`.

## E. Verification

- [ ] Phase detected from filesystem evidence (or SP0 asked) before routing.
- [ ] `params.json` exists and `params.rationale.md` verdict ≥ `GO-WITH-WARNINGS` before any run fires.
- [ ] `params.json:execution_mode` honoured (`nextflow` → runner; `manual` → recipes).
- [ ] After running the next-step sub-skill, its artifact was named explicitly in the handoff.
- [ ] Structural: `python3 <skill-forge>/bin/skill-lint.py $NANOBC_HOME` exits 0 with zero FAILs.
- [ ] CPU-only: `bash runners/nextflow-runner/test_pipeline_smoke.sh` and `bash runners/bash-recipes/test_smoke.sh` both exit 0.
- [ ] Update check: `pixi run update-check` (or `python3 bin/skill-update-check.py`) returns UP-TO-DATE / LOCAL-AHEAD.

## Provenance

Authored and revised following the [skill-forge](https://github.com/cheahhl814/skill-forge)
meta-skill conventions (BettaMt phased evidence chain, verdict gates, ask-user
stop points, signature libraries, bash-recipes/nextflow-runner dual path,
docs-corpus, update-check). Pattern sources:

- **BettaMt-agents** — https://github.com/cheahhl814/BettaMt-agents
- **bacterial-genome-analysis** (v5.x layout reference) — https://github.com/cheahhl814/bacterial-genome-analysis
- **amr-gene-screening** — https://github.com/cheahhl814/amr-gene-screening
- **nf-skill** — https://github.com/cheahhl814/nf-skill (DSL2 + nf-core conventions)
- **nf-edna v1.1.4** (pipeline-into-runners precedent) — https://github.com/cheahhl814