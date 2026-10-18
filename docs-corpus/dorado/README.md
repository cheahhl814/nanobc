# Dorado — offline docs snapshot

Source: https://raw.githubusercontent.com/nanoporetech/dorado/master/README.md
Captured: 2026-10-18 (verbatim GitHub README capture — fallback source #2 of the
skill-forge 3-source chain; the verbatim `--help` capture is unavailable
 because Dorado is a GPU binary absent from corpus-build hosts).
Licence: Oxford Nanopore Technologies PLC Public License v1.0 — (c) ONT PLC.
Dorado has NO conda/bioconda/pixi package; it is invoked via `params.dorado_bin`.
For all flags/defaults run `dorado -h` and `dorado <subcommand> -h` on the host.

---

# Dorado

Dorado is a high-performance, easy-to-use, open source analysis engine for Oxford Nanopore reads.

Detailed information about Dorado and its features is available in the [Dorado Documentation](https://software-docs.nanoporetech.com/dorado/latest/).

## Features

* One executable with sensible defaults, automatic hardware detection and configuration.
* Runs on Apple silicon (M series) and Nvidia GPUs including multi-GPU with linear scaling.
* Modified basecalling (5mC, 5hmC, 6mA).
* Duplex basecalling.
* Simplex barcode classification.
* Support for aligned read output in SAM/BAM.
* Initial support for poly(A) tail estimation.
* Support for single-read error correction (HERRO).
* POD5 support for highest basecalling performance.
* Based on libtorch, the C++ API for pytorch.

If you encounter any problems building or running Dorado, please report an issue at https://github.com/nanoporetech/dorado/issues.

## Installation

First, download the relevant installer for your platform (tar.gz / zip from https://github.com/nanoporetech/dorado/releases and the ONT CDN, e.g. `dorado-2.1.0-linux-x64`). Extract the archive, then either call the binary by full path (`/path/to/dorado-x.y.z-linux-x64/bin/dorado basecaller hac pod5s/ > calls.bam`) or add the bin path to `$PATH`.

## Platforms

Dorado is heavily-optimised for Nvidia A100 and H100 GPUs (maximal performance) and supported on:

| Platform | GPU/CPU | Minimum Software Requirements |
| --- |---------|--------------|
| Linux x86_64 | (G)V100, A100, H100 | CUDA Driver >= 525.105 |
| Linux arm64 | Jetson Orin, Jetson Thor, DGX Spark | Linux for Tegra >= 36.4.3 (JetPack >= 6.2) |
| Windows x86_64 | (G)V100, A100, H100 | CUDA Driver >= 529.19 |
| Apple | Apple Silicon (M series) | macOS >= 14 |

Linux x64 or Windows systems not listed above but with Nvidia GPUs with >= 8 GB VRAM and architecture from Pascal onwards (except P100/GP100) are not widely tested but expected to work.

## Performance tips

1. Dorado will automatically detect your GPU's free memory and select an appropriate batch size.
2. Dorado will automatically run in multi-GPU `cuda:all` mode. With a heterogeneous GPU collection, select the faster GPUs using the `--device` flag (e.g. `--device cuda:0,2`).
3. On Windows, set "CUDA - Sysmem Fallback Policy" to "Prefer No Sysmem Fallback" for a significant performance improvement.

## Running

To see all options and their defaults, run `dorado -h` and `dorado <subcommand> -h`.

### Simplex basecalling
`dorado basecaller hac pod5s/ > calls.bam` — automatically downloads the `hac` model; a single file may replace the directory.

### DNA adapter and primer trimming
Dorado can detect and remove adapter/primer sequences. NOTE: if demultiplexing later, trimming primers can remove barcode-flanking regions and prevent demultiplexing.

### Modified basecalling
`dorado basecaller hac,5mCG_5hmCG,6mA pod5s/ > calls.bam` — comma-separated list of modification models appended to the basecalling model.

### Duplex
`dorado duplex sup pod5s/ > duplex.bam`

### Alignment
`dorado aligner <index> <reads> > aligned.bam` (internally minimap2); or basecall+align with `--reference <index>`.

### Sequencing summary
`dorado summary <bam> > summary.tsv` — read-level TSV.

### Barcode classification
For existing basecalls or producing classified basecalls directly (see `dorado barcoding -h`).

### Poly(A) tail estimation
Enable with `--estimate-poly-a` on `basecaller`.

### Read error correction / assembly polishing
`dorado correct reads.fastq > corrected_reads.fasta` (HERRO; not on DGX Spark).
`dorado polish <draft> <aligned reads>` — haploid polishing tool.

## Available basecalling models

Model list: https://software-docs.nanoporetech.com/dorado/latest/models/list/ — Dorado can download models automatically; `dorado download --model all` fetches all.

## Troubleshooting

https://software-docs.nanoporetech.com/dorado/latest/troubleshooting/troubleshooting/

## Licence and Copyright

(c) 2025 Oxford Nanopore Technologies PLC. Distributed under the Oxford Nanopore Technologies PLC Public License v1.0 (https://nanoporetech.com).
