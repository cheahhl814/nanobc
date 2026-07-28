// dorado has no conda/bioconda package (ONT ships it as a standalone GPU
// binary), so unlike the other tools here it is invoked directly via
// params.dorado_bin rather than through a pixi env.

process dorado_basecall_lsk {
  tag "${meta.id}"
  label 'dorado'
  publishDir "${params.outdir}/dorado_basecall_lsk", mode: 'copy'
  errorStrategy 'retry'
  maxRetries 2

  input:
  tuple val(meta), path(pod5)

  output:
  tuple val(meta), path("${meta.id}.fastq.gz"), emit: fastq

  script:
  """
  ${params.dorado_bin} basecaller -x "cuda:all" \
    --emit-fastq ${params.model} ${pod5} | gzip > ${meta.id}.fastq.gz
  """
}

process transfer {
  tag "${meta.id}"
  label 'transfer'
  executor 'local'
  errorStrategy 'retry'
  maxRetries 3

  input:
  tuple val(meta), path(fastq)

  output:
  path "${meta.id}.checkpoint"

  script:
  """
  echo ${params.transfer_dest} | tr ":" " " | while read prompt dir ; do
      ssh \$prompt "mkdir -p \$dir"
  done

  rsync -r --progress ${fastq} ${params.transfer_dest}
  touch ${meta.id}.checkpoint
  """
}

process dorado_basecall {
  tag "${meta.id}"
  label 'dorado'
  errorStrategy 'retry'
  maxRetries 2

  input:
  tuple val(meta), path(pod5)

  output:
  tuple val(meta), path("${meta.id}.bam"), emit: bam

  script:
  """
  ${params.dorado_bin} basecaller -x "cuda:all" \
    --kit-name ${params.kitname} \
    ${params.model} ${pod5} > ${meta.id}.bam
  """
}

process bam2fq {
  tag "${meta.id}"
  label 'samtools'
  errorStrategy 'retry'
  maxRetries 2

  input:
  tuple val(meta), path(bam)

  output:
  tuple val(meta), path("fastq_out/*.fastq.gz"), emit: fastqs

  script:
  """
  mkdir -p fastq_out

  pixi run --manifest-path ${baseDir}/envs/samtools/pixi.toml \
    samtools view ${bam} | \
  awk -v outdir="fastq_out" '
  BEGIN { OFS="\\n" }
  {
      bc="unknown"
      for (i=12; i<=NF; i++) {
          if (\$i ~ /^BC:Z:/) {
              bc = substr(\$i, 6)
              break
          }
      }

      fq = outdir "/" bc ".fastq"
      print "@"\$1 >> fq
      print \$10 >> fq
      print "+" >> fq
      print \$11 >> fq
  }
  '

  gzip -f fastq_out/*.fastq
  """
}

process concat_fastq {
  tag "${barcode}"
  label 'samtools'
  publishDir "${params.outdir}/fastq", mode: 'copy'
  errorStrategy 'retry'
  maxRetries 2

  input:
  tuple val(barcode), path(fastqs)

  output:
  path "${barcode}.fastq.gz", emit: fastq

  script:
  """
  for fq in ${fastqs} ; do
      pixi run --manifest-path ${baseDir}/envs/samtools/pixi.toml \
        zcat \$fq | gzip >> ${barcode}.fastq.gz
  done
  """
}

process total_bases {
  label 'seqtk'
  publishDir "${params.outdir}", mode: 'copy'
  errorStrategy 'retry'
  maxRetries 2

  input:
  path fastqs

  output:
  path "total_bases.tsv"

  script:
  """
  echo -e "barcode\ttotal_bases" > total_bases.tsv

  fqs=\$(printf "%s\\n" ${fastqs} | sort)
  fqs=\$(printf "%s\\n" \$fqs | awk '
      /unclassified/ { unclassified = unclassified \$0 "\\n"; next }
      { print }
      END { printf "%s", unclassified }
  ')

  for fq in \$fqs ; do
      name=\$(basename \$fq | sed "s/\\.fastq\\.gz//")
      total_bases=\$(pixi run --manifest-path ${baseDir}/envs/seqtk/pixi.toml \
        seqtk fqchk \$fq | grep "ALL" | cut -f2)
      echo -e "\$name\t\$total_bases" >> total_bases.tsv
  done
  """
}
