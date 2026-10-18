# nanobc — Tool Documentation Corpus

Ingested 2026-10-18 per the skill-forge 3-source fallback chain (verbatim
`--help` capture → GitHub/docs capture → web search). Each subdirectory holds
offline documentation for a tool the skill's runbook relies on, so tool flags
are never hallucinated from memory.

## Tools by Phase

| Phase | Tool | Directory | Source (fallback level) |
|------|-----------|------|------|
| run (both modes) | dorado | `dorado/` | #2 — verbatim GitHub README capture (no conda/pixi package; not installable on corpus-build hosts, so `--help` capture unavailable) |
| run (barcoded path) | samtools | `samtools/` | #1 — verbatim capture of the **pinned** env (`pixi run --manifest-path runners/nextflow-runner/envs/samtools/pixi.toml samtools --help` / `view --help`, samtools 1.24) |
| run | seqtk | `seqtk/` | #1 — verbatim capture of the pinned env (`seqtk 1.5`, usage listing) |
| run (nextflow mode) | nextflow | `nextflow/` | #1 — verbatim capture (`nextflow help run`, 26.04.6 — covers `-preview`/`-dry-run` naming) |

## Notes

- Dorado flags/defaults vary by build: always confirm with `dorado -h` and
  `dorado <subcommand> -h` on the run host before relying on a flag.
- The pipeline's own source (`runners/nextflow-runner/main.nf`,
  `modules/dorado.nf`, `nextflow.config`) remains the primary ground truth
  for its Dorado/samtools invocations; this corpus covers tool-level flags.
- Refresh: re-run the capture commands above or re-fetch the Dorado README;
  keep each entry pinned to the version actually used by the runbook.