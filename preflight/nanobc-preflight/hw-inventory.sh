#!/usr/bin/env bash
# hw-inventory.sh — live hardware/software inventory for the nanobc preflight
# audit trail (v1.0).
#
# Emits a Markdown evidence block (stdout) describing the CURRENT host's
# compute capabilities: CPU, RAM, NVIDIA GPU model/VRAM/driver/CUDA, disk free
# space at a target path, kernel/OS, and tool availability. Preflight §2g (v2.1.0)
# runs this instead of relying on any recorded or remembered host knowledge —
# hardware claims are grounded per-run, and machine identities are NOT captured
# (no hostname, MACs, serials — see the privacy note below).
#
# Usage:
#   ./hw-inventory.sh [path-for-disk-check]     # default: $PWD
#
# Exit codes: 0 always (missing tools degrade to "not detected" lines — a
# missing GPU or nvidia-smi is evidence, not failure; verdict weighting happens
# in the preflight reasoning, not here).
set -u

DISK_PATH="${1:-$PWD}"

md() { printf '%s\n' "$*"; }

md "## Host hardware inventory (live, $(date -u +%Y-%m-%dT%H:%M:%SZ))"
md ""
md "_Recorded by \`hw-inventory.sh\`; replaces any recorded/remembered host knowledge. Identities (hostname, serials) intentionally not captured — specs only._"
md ""

# --- CPU ---
if command -v lscpu >/dev/null 2>&1; then
  cpu_model="$(lscpu | awk -F': *' '/Model name/ {print $2; exit}')"
  cores="$(lscpu | awk -F': *' '/^CPU\(s\):/ {print $2; exit}')"
  arch="$(lscpu | awk -F': *' '/^Architecture:/ {print $2; exit}')"
  md "- CPU: ${cpu_model:-not detected} (${cores:-?} logical cores, ${arch:-?})"
else
  md "- CPU: lscpu not available"
fi

# --- RAM ---
if command -v free >/dev/null 2>&1; then
  ram_line="$(free -h | awk '/^Mem:/ {print "total " $2 ", used " $3 ", avail " $7}')"
  md "- RAM: ${ram_line:-not detected}"
else
  md "- RAM: free not available"
fi

# --- NVIDIA GPU (model / VRAM / driver / CUDA) ---
GPU_OK=0
if command -v nvidia-smi >/dev/null 2>&1; then
  if gpu_csv="$(nvidia-smi --query-gpu=name,memory.total,driver_version \
                --format=csv,noheader 2>/dev/null)"; then
    GPU_OK=1
    md "- GPU(s):"
    while IFS=, read -r name vram driver; do
      # trim surrounding CSV padding but keep the model name's internal spaces
      name="${name#"${name%%[! ]*}"}"; name="${name%"${name##*[! ]}"}"
      md "  - \`$name\` — VRAM ${vram# }, driver ${driver# }"
    done <<< "$gpu_csv"
    cuda="$(nvidia-smi 2>/dev/null | awk '/CUDA Version/ {print gensub(/.*CUDA Version: *([0-9.]+).*/, "\\1", "1", $0); exit}')"
    [[ -n "$cuda" ]] && md "  - CUDA (driver-side): ${cuda}" || md "  - CUDA (driver-side): not reported by nvidia-smi"
  else
    md "- GPU: nvidia-smi present but failed to run — capture its stderr in the preflight evidence (driver/library mismatch candidates, §2e)"
  fi
else
  md "- GPU: no NVIDIA driver on this host (nvidia-smi absent) — basecalling must run on a different node or is unattempted here"
fi

# --- Disk ---
if df -h "$DISK_PATH" >/dev/null 2>&1; then
  disk="$(df -h "$DISK_PATH" | awk 'NR==2 {print $4 " free of " $2 " on " $6}')"
  md "- Disk ($DISK_PATH): ${disk:-not detected}"
else
  md "- Disk ($DISK_PATH): not detectable"
fi

# --- OS / kernel ---
pretty="$(awk -F'"' '/PRETTY_NAME/ {print $2; exit}' /etc/os-release 2>/dev/null)"
md "- OS/kernel: ${pretty:-unknown} / $(uname -sr 2>/dev/null || echo unknown)"

# --- Tools the runbook depends on ---
for tool in dorado nextflow pixi jq; do
  if command -v "$tool" >/dev/null 2>&1; then
    case "$tool" in
      dorado)    ver="$("$tool" --version 2>/dev/null | head -1 || echo 'present (version query failed)')" ;;
      nextflow)  ver="$("$tool" -v 2>/dev/null | head -1 || echo 'present')" ;;
      pixi)      ver="$("$tool" --version 2>/dev/null | head -1 || echo 'present')" ;;
      jq)        ver="$(jq --version 2>/dev/null || echo present)" ;;
    esac
    md "- $tool: ${ver}"
  else
    md "- $tool: NOT FOUND"
  fi
done

exit 0