# runners/bash-recipes — the manual execution path

> **v1.0.1** (recipes). Thin bash executors for `nf-nanopore-basecalling`, mirroring
> `modules/dorado.nf` + `main.nf` command-for-command. The Nextflow pipeline remains
> the **source of truth**; these recipes are an alternative executor, not a second
> implementation to maintain in parallel.

## Why two paths?

| | **Nextflow runner** (default) | **Manual bash recipes** (this dir) |
| --- | --- | --- |
| When | HPC/SLURM, cohort runs (many pod5 chunks), interruptible runs, when you want trace/report/timeline artifacts | Single workstation, one-off 1–2 chunk basecalls, environments where Nextflow is absent or overkill, isolating a single step while debugging |
| Resume | `-resume` caches completed tasks | none — every pod5 chunk re-runs on retry |
| Retries | per-process `errorStrategy 'retry'` (2–3×) | none — stop and re-run (or narrow the `--pod5` glob per chunk) |
| Transfer | `transfer` process, retries | optional `--transfer_dest` flag (no retries) |
| Evidence | `.nextflow.log` + work-dir `.command.err/…` | one transcript per invocation: `$OUTDIR/logging/manual_run_<ts>.log` |
| Output layout | **identical** — LSK: `$OUTDIR/dorado_basecall_lsk/`; barcoded: `$OUTDIR/fastq/` incl. `unknown` | identical |
| Hardware | unchanged: dorado needs a CUDA GPU + model dir | unchanged |

Selection is a run-time choice pinned by `nanobc-preflight` into `params.json:execution_mode`
(`"nextflow"` | `"manual"`); `nanobc-run` honours it (SP1a / SP6 in the skills' docs).

## Files

| File | Role |
| --- | --- |
| `run_basecalling.sh` | The driver — validation parity with `main.nf` (missing `--pod5`/`--model`, unmatched glob, dorado resolvability), then per-chunk basecalling on the LSK or barcoded path, optional transfer |
| `demux_bam.sh` | The `bam2fq` equivalent — samtools (pinned pixi env, or PATH) + the awk `BC:Z:` splitter, publishing `<barcode>.fastq.gz` incl. `unknown` |
| `test_smoke.sh` | CPU-only smoke test — script syntax, awk lock-step against `modules/dorado.nf`, functional demux of a synthetic BC:Z BAM. Needs **no GPU, no dorado, no model** |

## Usage

```bash
# flags (kitname picks the path, exactly like main.nf):
./run_basecalling.sh --pod5 "input_folder/N046/*.pod5" \
                     --model /path/to/dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
                     --kitname SQK-LSK114 --outdir ./results

# or from preflight params.json:
./run_basecalling.sh --params-file /path/to/run-dir/params.json

# validate the recipes on any CPU-only machine:
./test_smoke.sh
```

Exit codes: `0` ok · `1` usage/validation · `2` demux failure · `3` transfer failure.

## Divergence rule

If a process script in `modules/dorado.nf` changes, mirror the change here in the
**same commit** — `test_smoke.sh` check #2 enforces awk lock-step automatically.
Historical example: the missing-`set -o pipefail` bug in `dorado_basecall_lsk`
(fixed 2026-08-03 in the pipeline) would have shipped silently into these recipes
without this rule.

## Provenance

Added v1.2.0 of the `nanobc-*` skill bundle, following the skillforge convention for
the bash-recipes/nextflow-runner dual path. The recipes consume the same
`envs/*/pixi.toml` environments as the pipeline.