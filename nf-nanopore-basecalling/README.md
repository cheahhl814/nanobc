# nf-nanopore-basecalling

Nextflow (DSL2) pipeline for Nanopore basecalling with Dorado, followed by
barcode demultiplexing and basic QC (total base counts).

Two paths through the pipeline, selected by `--kitname`:

- **LSK kits** (e.g. `SQK-LSK114`): `dorado_basecall_lsk` emits FASTQ directly;
  optionally rsynced to a remote destination via `--transfer_dest`.
- **Barcoded kits** (e.g. `SQK-RBK114`): `dorado_basecall` emits a BAM, which is
  then demultiplexed per barcode (`bam2fq`), concatenated across pod5 chunks
  (`concat_fastq`), and summarized (`total_bases`).

## Requirements

- [Nextflow](https://www.nextflow.io/) >= 23.04
- [Dorado](https://github.com/nanoporetech/dorado) — installed separately as a
  standalone binary (no conda/bioconda package exists for it). Either put it
  on `$PATH` or point `--dorado_bin` at its location. A CUDA-capable GPU is
  required for basecalling.
- [pixi](https://pixi.sh/) — used to provide reproducible, pinned `samtools`
  and `seqtk` environments (see `envs/`). No manual install of these tools is
  needed; each process invokes `pixi run --manifest-path envs/<tool>/pixi.toml ...`
  on demand.

## Usage

```bash
nextflow run main.nf -params-file params/example.json -profile slurm
```

Or pass parameters directly:

```bash
nextflow run main.nf \
  --pod5 "input_folder/N046/*.pod5" \
  --outdir results/N046 \
  --kitname SQK-LSK114 \
  --model /path/to/dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
  --dorado_bin /opt/dorado/bin/dorado \
  -profile slurm
```

`--pod5` and `--model` are required; the pipeline exits early with an error if
either is missing.

### Parameters

| Parameter         | Description                                                        | Default        |
|-------------------|----------------------------------------------------------------------|----------------|
| `--pod5`          | Glob of input pod5 chunks (required)                                 | —              |
| `--outdir`        | Output directory                                                      | `./results`    |
| `--kitname`       | Sequencing kit, e.g. `SQK-LSK114` or `SQK-RBK114`                     | `SQK-LSK114`   |
| `--model`         | Path to Dorado basecalling model (required)                          | —              |
| `--dorado_bin`    | Path to the Dorado binary                                             | `dorado` (on `$PATH`) |
| `--transfer_dest` | Optional `user@host:/path` to rsync LSK FASTQ output to               | (skipped if empty) |

### Profiles

- `slurm` — submits jobs to a SLURM cluster (GPU partition for Dorado, CPU
  partitions for samtools/seqtk).
- `local` — runs everything on the local machine, no job submission.

## Run reports

Each run writes an execution trace, HTML report, and timeline under
`<outdir>/pipeline_info/`.
