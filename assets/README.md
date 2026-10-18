# assets — downloaded basecalling models (and other large local artifacts)

This directory holds **gitignored local assets** for nanobc runs. Nothing under
it is pushed to GitHub except this README — consistent with the
bacterial-genome-analysis `assets/` convention.

## Basecalling models

Dorado basecaller models (e.g. `dna_r10.4.1_e8.2_400bps_sup@v5.2.0`) are large
directory trees downloaded from ONT. `nanobc-preflight` SP5 / §2c recommend
downloading into `assets/models/`:

```bash
# default recommendation (preflight §2c / SP5) — --models-directory lands the
# model in the right place regardless of your cwd:
"$DORADO_BIN" download --list                                   # models available on THIS dorado build
"$DORADO_BIN" download --model dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
    --models-directory "$NANOBC_HOME/assets/models"

# then point the run's --model at:
"$NANOBC_HOME/assets/models/dna_r10.4.1_e8.2_400bps_sup@v5.2.0"
```

Notes:

- The model path is **per-run** (`params.json:model`, absolute path); models
  are shared across runs, so one download serves every `$RUN_DIR`.
- Dorado can otherwise auto-download models on first use — but pre-downloading
  here keeps the preflight `--model` check (§2c) green and makes the exact
  model version visible on disk before committing GPU time. (For name/variant
  forms WITHOUT `--models-directory`, Dorado deletes the auto-downloaded model
  after every run — see `docs-corpus/dorado/models.md`.) nanobc itself uses
  path-based selection, so this pre-download is the standard route.
- Model names/versions must never be invented — enumerate with `dorado download --list`
  (matches the installed Dorado) or see [Dorado's model list](https://software-docs.nanoporetech.com/dorado/latest/models/list/);
  download/selection/discovery mechanics are captured in `docs-corpus/dorado/models.md`.

## What belongs here vs. what doesn't

| Fits (`assets/`) | Doesn't fit |
| --- | --- |
| Dorado model directories under `assets/models/` | Run outputs (each run keeps its own `$RUN_DIR`/`$OUTDIR`) |
| Other reproducibly re-downloadable large artifacts | Anything with a license forbidding redistribution… **it never ships anyway** — but prefer re-downloads over hoarding |
| — | Anything machine-specific (see `preflight/nanobc-preflight` §2g: hardware evidence is captured live per run, into `$RUN_DIR/params.rationale.md`) |

## Why the content is gitignored

Downloads can be GBs and are trivially reproducible (`dorado download`). Pushing
them would bloat the repo and risk redistributing ONT-licensed model weights;
the README is the only tracked file here (`/assets/*` ignored,
`!/assets/README.md`).