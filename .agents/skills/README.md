# nf-nanopore-basecalling agentic skills

Companion skills for the `nf-nanopore-basecalling` Nextflow pipeline (Dorado basecalling → demultiplexing → base-count QC). These define the agentic layer — pre-flight parameter/config preparation, post-run failure interpretation, and post-run QC. The pipeline itself is untouched; the skills consume its inputs and outputs.

## Skills

| Skill | Purpose | When |
|---|---|---|
| `nanobc-run` | End-to-end orchestrator: detect stage, route to the right skill, hand off | User says "run the basecalling pipeline" / "basecall this pod5 folder" |
| `nanobc-preflight` | Produce `params.json` + `params.rationale.md` (+ optional `nextflow.config.<env>.local` override) from a pod5 folder, model, and kit name | Before `nextflow run` |
| `nanobc-debug` | Diagnose a failed run, write `diagnosis.md` with top-3 hypotheses | After a failure |
| `nanobc-qc` | Check basecalling/demux output integrity and base/read counts, write `report.md` | After success |

**Recommended entry point for new users:** `nanobc-run`. It detects the current stage (preflight / run / debug / qc) and routes to the appropriate skill.

## Pipeline location

Each skill resolves `NANOBC_HOME` in this order:
1. `$NANOBC_HOME` env var (set by user)
2. Sibling directory `../nf-nanopore-basecalling` next to this skill folder
3. Asks the user

## Relocating

This folder is meant to live one directory level above the `nf-nanopore-basecalling/` pipeline directory, so the pipeline's working tree stays clean and shippable on its own. Recommended layout:

```
Nextflow/
├── nf-nanopore-basecalling-agents/
│   └── .agents/skills/           # this folder
│       ├── nanobc-run/           # entry point — start here
│       ├── nanobc-preflight/
│       ├── nanobc-debug/
│       └── nanobc-qc/
└── nf-nanopore-basecalling/       # pipeline (clean, shippable, its own git repo)
```

**Why `.agents/` (with the `s`)?** This is the cross-tool Agent Skills standard convention. `pi`, OpenCode, and Codex all auto-scan `.agents/skills/` from `cwd` up to the repo root. The singular `.agent/` is silently ignored by all of them. Claude Code is the one exception — it scans `.claude/skills/`; see anthropics/claude-code#33733.

To install globally for one user:

```bash
ln -s "$(pwd)" ~/.pi/agent/skills/nanobc-bundle
# or symlink each skill individually:
ln -s "$(pwd)/nanobc-run"        ~/.pi/agent/skills/
ln -s "$(pwd)/nanobc-preflight"  ~/.pi/agent/skills/
ln -s "$(pwd)/nanobc-debug"      ~/.pi/agent/skills/
ln -s "$(pwd)/nanobc-qc"         ~/.pi/agent/skills/
```

## Extending

The four skills share a common principle: **the agent reasons; the pipeline executes**. When you encounter a new failure mode, add a row to the signature table in `nanobc-debug/SKILL.md` rather than writing a script. When you discover a new QC concern, add a check section to `nanobc-qc/SKILL.md`. The skill files are versioned alongside the pipeline (or separately, as you prefer).

## What this pipeline does NOT have (unlike BettaMt)

- No assembly, no reference genome, no annotation step — QC here is about **run/output integrity** (did basecalling and demultiplexing produce sane, complete, non-corrupt FASTQ), not biological correctness.
- No per-process `withName:` overrides — `nextflow.config` here uses **labels** (`dorado`, `samtools`, `seqtk`, `transfer`), so any user-side override must use `withLabel:`, not `withName:`.
- Dorado itself has no conda/pixi package (ONT ships it as a standalone GPU binary) — it is invoked via `params.dorado_bin`, resolved from `$PATH` by default. Its version is **not** pinned by the repo; the preflight/rationale step is the only place that version gets recorded per run.
