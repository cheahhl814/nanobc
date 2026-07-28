# nf-nanopore-basecalling-agents

A Nextflow pipeline for Dorado-based Nanopore basecalling, barcode demultiplexing, and base-count QC, paired with a set of agentic skills that operate around the pipeline.

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

This repo's `local` profile has been run on a Threadripper PRO 7975WX workstation with an **NVIDIA RTX PRO 6000 Blackwell Max-Q (96 GB VRAM, 300 W TDP)** — PCI `10de:2bb4`. Notes specific to this card (CUDA-OOM is unlikely given the VRAM headroom; Max-Q's lower power/cooling target makes thermal throttling worth checking under Dorado's sustained load; the SLURM `dorado` label's hardcoded `--gres=gpu:3g.39gb:1` is an A100 MIG profile and does **not** describe this card) are in `nanobc-preflight` §2e.1 and `nanobc-debug` §1.6.
