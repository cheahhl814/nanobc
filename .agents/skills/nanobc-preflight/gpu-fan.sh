#!/usr/bin/env bash
set -euo pipefail

query_attr() {
    nvidia-settings -q "$1" 2>/dev/null | sed -nE "s/^ *Attribute .*\): ([0-9]+)\.?$/\1/p" | head -1
}

probe_target_attr() {
    if nvidia-settings -q GPUTargetFanSpeed >/dev/null 2>&1; then
        echo GPUTargetFanSpeed
    elif nvidia-settings -q GPUFanControlTarget >/dev/null 2>&1; then
        echo GPUFanControlTarget
    else
        echo ""
    fi
}

require_x() {
    if ! command -v nvidia-settings >/dev/null 2>&1; then
        echo "ERROR: nvidia-settings not found. Install it (e.g. apt install nvidia-settings)." >&2
        echo "Fan control runs over X11/NV-CONTROL; nvidia-smi can only query fans." >&2
        exit 2
    fi
    if ! nvidia-settings -q GPUFanControlState >/dev/null 2>&1; then
        echo "ERROR: cannot query GPUFanControlState via X display (DISPLAY=${DISPLAY:-<unset>})." >&2
        echo "Either no reachable X server, or this GPU/driver hides fan control from the OS." >&2
        exit 2
    fi
}

fan_rpm() {
    local rpm
    rpm=$(query_attr GPUCurrentFanSpeedRPM)
    [ -n "$rpm" ] && echo "$rpm" || echo "?"
}

usage() {
    cat <<'EOF'
gpu-fan.sh — manual NVIDIA fan control for nf-nanopore-basecalling

usage:
  gpu-fan.sh status           read-only fan snapshot (nvidia-smi temp/fan% + state/RPM)
  gpu-fan.sh max              force fan to 100% (manual control), verify read-back
  gpu-fan.sh set <0-100>      force fan to a specific percent
  gpu-fan.sh auto             hand fan curve back to GPU firmware
  gpu-fan.sh help             this text

notes:
  - Requires a running X server + nvidia-settings (NV-CONTROL); nvidia-smi can only query fans.
  - Settable attribute name varies by driver (GPUTargetFanSpeed vs GPUFanControlTarget), probed automatically.
  - Most professional/datacenter GPUs expose no OS fan knob — the script reports instead of failing.
EOF
}

cmd_status() {
    echo "== GPU fan status =="
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=name,temperature.gpu,fan.speed --format=csv,noheader
    else
        echo "nvidia-smi: unavailable or failing (check driver/library version mismatch)."
    fi
    if command -v nvidia-settings >/dev/null 2>&1 && nvidia-settings -q GPUFanControlState >/dev/null 2>&1; then
        echo "fan control: $(query_attr GPUFanControlState) (1=manual, 0=auto)"
        echo "fan target:  $(query_attr "$(probe_target_attr)")"
        echo "fan RPM:     $(fan_rpm)"
    else
        echo "nvidia-settings: not available / no X display — fan control state unknown."
    fi
}

cmd_max() {
    require_x
    local target
    target=$(probe_target_attr)
    if [ -z "$target" ]; then
        echo "ERROR: no settable fan-target attribute (tried GPUTargetFanSpeed, GPUFanControlTarget)." >&2
        echo "This GPU manages fans in firmware with no OS knob — nothing to control." >&2
        exit 2
    fi
    local before_rpm after_rpm actual
    before_rpm=$(fan_rpm)
    nvidia-settings -a GPUFanControlState=1
    nvidia-settings -a "$target=100"
    after_rpm=$(fan_rpm)
    actual=$(query_attr "$target")
    if [ "$actual" != "100" ]; then
        echo "WARNING: fan target reads back as '$actual', not 100 — manual fan control may be unsupported here." >&2
    else
        echo "fan target set to 100 (verified). RPM: $before_rpm -> $after_rpm"
    fi
    echo "NOTE: fans stay at max until you run '$0 auto'."
}

cmd_set() {
    local pct="${1:-}"
    if ! [[ "$pct" =~ ^[0-9]+$ ]] || [ "$pct" -lt 0 ] || [ "$pct" -gt 100 ]; then
        echo "usage: $0 set <0-100>" >&2
        exit 2
    fi
    require_x
    local target
    target=$(probe_target_attr)
    if [ -z "$target" ]; then
        echo "ERROR: no settable fan-target attribute — firmware-controlled fan." >&2
        exit 2
    fi
    nvidia-settings -a GPUFanControlState=1
    nvidia-settings -a "$target=$pct"
    echo "fan target set to $pct. current RPM: $(fan_rpm)"
}

cmd_auto() {
    require_x
    nvidia-settings -a GPUFanControlState=0
    echo "fan control returned to automatic (firmware curve)."
}

case "${1:-}" in
    status) cmd_status ;;
    max) cmd_max ;;
    set) cmd_set "${2:-}" ;;
    auto) cmd_auto ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
esac
