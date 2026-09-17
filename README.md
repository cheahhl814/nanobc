# nanobc

A Nextflow pipeline for Dorado-based Nanopore basecalling, barcode demultiplexing, and output QC, paired with a set of agentic skills that operate around the pipeline.

## What's in this repo

| Path | What it is | Ship it? |
|---|---|---|
| `nf-nanopore-basecalling/` | Nextflow DSL2 pipeline (pixi-managed samtools/seqtk; Dorado via `--dorado_bin`) | ✅ |
| `.agents/skills/` | Agent Skills (SKILL.md) for pi, OpenCode, Codex | ✅ |
| `.gitignore` | Excludes Nextflow `work/`, `.nextflow/`, `results/` | ✅ |

## Quick start — pipeline

`samtools`/`seqtk` are invoked via `pixi run --manifest-path envs/<tool>/pixi.toml ...` from inside each process's `script:` block, so you do **not** wrap the `nextflow` invocation itself in `pixi run`. Dorado has no conda/pixi package (ONT ships it as a standalone GPU binary) — put it on `$PATH` or pass `--dorado_bin /path/to/dorado`.

```bash
cd nf-nanopore-basecalling
nextflow run main.nf -profile slurm \
  --pod5   "input_folder/N046/*.pod5" \
  --model  /path/to/dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
  --kitname SQK-LSK114
```

See [`nf-nanopore-basecalling/README.md`](nf-nanopore-basecalling/README.md) for the full parameter table, profiles, and output layout.

## The agentic interface

See [`.agents/skills/README.md`](.agents/skills/README.md) for the skill list (`nanobc-run`, `nanobc-preflight`, `nanobc-debug`, `nanobc-qc`) and how they resolve the pipeline location (`$NANOBC_HOME`, defaulting to the sibling `nf-nanopore-basecalling/` directory in this repo).

## Known local host

The `local` profile targets a CUDA-capable workstation GPU with large VRAM. Card-specific runbook notes (why CUDA-OOM is unlikely given the VRAM headroom, how to check thermal throttling under Dorado's sustained load, and why the shipped SLURM `clusterOptions` are placeholders that may not match your cluster) live in the skill files: `nanobc-preflight` §2e.1 and `nanobc-debug` §1.6.
