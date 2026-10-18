#!/usr/bin/env nextflow

nextflow.enable.dsl=2

// Parameters
params.pod5 = ""              // Glob of input pod5 chunks, e.g. "input_folder/N046/*.pod5"
params.outdir = "${launchDir}/results"
params.kitname = "SQK-LSK114" // e.g. SQK-LSK114 or SQK-RBK114
params.model = ""             // Path to dorado basecalling model
params.dorado_bin = "dorado"  // dorado has no conda package, so this is a binary path/name
params.transfer_dest = ""     // Optional user@host:/path for LSK output; skipped if empty

// Per-chunk id derivation: collision-proof across naming conventions.
// Path.baseName strips ONLY the final extension, so chunk-split deliveries
// like `N046.pod5.001` … `N046.pod5.012` all baseName to `N046.pod5` and every
// chunk published the SAME `${id}.fastq.gz` — publishDir 'copy' then overwrote
// the previous chunk, leaving only the last one in $outdir (the rest
// recoverable only from work/). Fixed v0.1.1: strip the `.pod5` container
// marker only, keeping every other name part (including any chunk index):
//   N046_001.pod5 -> N046_001    N046.pod5.001 -> N046.001
//   N046.001.pod5 -> N046.001    batch1.pod5   -> batch1
def pod5Id(pod5) {
  pod5.name.replaceAll(/\.pod5(?=(\.\d+)?$)/, '')
}

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

// Module inclusion
include { dorado_basecall_lsk; transfer; dorado_basecall; bam2fq; concat_fastq } from "./modules/dorado.nf"

workflow {
  // Help + param validation live INSIDE the workflow — top-level statements
  // mixed with script declarations (process/workflow/function definitions)
  // are rejected by newer Nextflow's strict script parsing (26.x); the old
  // top-level guards made the pipeline uncompileable there (fixed v0.1.1).
  params.help = params.help ?: false
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

  pod5_paths = file(params.pod5, checkIfExists: true)
  if (!(pod5_paths instanceof List)) pod5_paths = [pod5_paths]

  // Duplicate-id guard: two chunks mapping to the same id would silently
  // overwrite each other in publishDir — fail loudly instead (v0.1.1).
  def seen = [:]
  pod5_paths.each { f ->
    def id = pod5Id(f)
    if (seen.containsKey(id)) {
      log.error "pod5 id collision: '${seen[id]}' and '${f.name}' both map to id '${id}' — their outputs would overwrite each other in ${params.outdir}. " +
        "Rename the chunks so ${id} derivation distinguishes them (keep the distinguishing part before .pod5), then re-run."
      exit 1
    }
    seen[id] = f.name
  }

  pod5_ch = Channel.fromList(pod5_paths.collect { f -> [ [id: pod5Id(f)], f ] })

  if (params.kitname.contains('LSK')) {
    dorado_basecall_lsk(pod5_ch)
    if (params.transfer_dest) {
      transfer(dorado_basecall_lsk.out.fastq)
    }
  } else {
    dorado_basecall(pod5_ch)
    bam2fq(dorado_basecall.out.bam)
    // Aggregate per-barcode ACROSS chunks before publishing. Each chunk's
    // bam2fq task emits `<barcode>.fastq.gz` under the SAME name, so per-chunk
    // publishDir copies would overwrite each other (pre-v0.1.1: every chunk
    // after the first silently lost its reads; concat_fastq was off the DAG).
    // Re-wired v0.1.1: bam2fq no longer publishes; concat_fastq (below) owns
    // the barcode files in ${params.outdir}/fastq.
    // Per-chunk fastq file names are `<id>_<barcode>.fastq.gz` (v0.1.1) —
    // parse the barcode back out so grouping is by barcode, not chunk.
    concat_fastq(
      bam2fq.out.fastqs
        .map { meta, files ->
          files.collect { f ->
            def base = f.name.replaceFirst(/\.(fastq)(\.gz)?$/, '')
            def bc   = base.startsWith(meta.id + '_') ? base.substring(meta.id.length() + 1) : base
            tuple(bc, f)
          }
        }
        .flatMap()          // one (barcode, file) tuple per emitted fastq
        .groupTuple()       // group per barcode across ALL chunks
    )
  }
}
