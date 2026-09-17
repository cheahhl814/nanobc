#!/usr/bin/env nextflow

nextflow.enable.dsl=2

// Parameters
params.pod5 = ""              // Glob of input pod5 chunks, e.g. "input_folder/N046/*.pod5"
params.outdir = "${launchDir}/results"
params.kitname = "SQK-LSK114" // e.g. SQK-LSK114 or SQK-RBK114
params.model = ""             // Path to dorado basecalling model
params.dorado_bin = "dorado"  // dorado has no conda package, so this is a binary path/name
params.transfer_dest = ""     // Optional user@host:/path for LSK output; skipped if empty

// Help
params.help = false

def helpMessage() {
  log.info"""
  ========================================
  Nanopore (Dorado) Basecalling Pipeline
  ========================================

  Usage:
    nextflow run main.nf -params-file <params.json> [options]

  Nextflow-specific arguments:
    -profile                     Profile to use: slurm (on HPC) or local (on local machine without job submission)
    -params-file                 JSON file with inputs/parameters
    -resume                      Resume a previous run

  Pipeline options:
    --help                       Show this help message and exit

  Available options:
    --pod5                       Glob of input pod5 chunks
    --outdir                     Output directory [Default: ./results]
    --kitname                    Sequencing kit, e.g. SQK-LSK114 or SQK-RBK114
    --model                      Path to dorado basecalling model
    --dorado_bin                 Path to dorado binary [Default: dorado (on PATH)]
    --transfer_dest              user@host:/path to rsync LSK fastq output to (LSK only, optional)

  Example:
    nextflow run main.nf -params-file params/example.json -profile slurm
  """.stripIndent()
}

if (params.help) {
  helpMessage()
  exit 0
}

def missing = []
if (!params.pod5)  missing << '--pod5'
if (!params.model) missing << '--model'
if (missing) {
  log.error "Missing required parameter(s): ${missing.join(', ')}\n" +
    "Run with --help for usage."
  exit 1
}

// Module inclusion
include { dorado_basecall_lsk; transfer; dorado_basecall; bam2fq } from "./modules/dorado.nf"

workflow {
  pod5_ch = Channel.fromPath(params.pod5, checkIfExists: true)
    .map { it -> [ [id: it.baseName], it ] }

  if (params.kitname.contains('LSK')) {
    dorado_basecall_lsk(pod5_ch)
    if (params.transfer_dest) {
      transfer(dorado_basecall_lsk.out.fastq)
    }
  } else {
    dorado_basecall(pod5_ch)
    bam2fq(dorado_basecall.out.bam)
  }
}
