#!/usr/bin/env bash
# =============================================================================
# hardware_scan.sh — best-effort CPU/RAM/GPU probe, per-OS.
#
# Replaces cockpit_auth's Pascal `scan_hardware` op: same JSON output shape,
# same "never a hard error, missing tool just leaves that field empty/zero"
# behavior — this is only ever used to raise ollama_guard.php's model-size
# ceiling above its conservative 4B default, not to gate anything.
# GPU detection: NVIDIA via nvidia-smi, AMD via the kernel's own sysfs report
# (/sys/class/drm/card*/device/mem_info_vram_total — no vendor tool needed).
# Intel discrete GPU detection is still a real gap — no equivalently simple,
# universally-installed tool covers it.
#
# Output: {"ok":true,"os":"linux","cpu_cores":12,"ram_mb":32019,"gpu_name":"...","gpu_vram_mb":0}
# =============================================================================
set -uo pipefail

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

OS_NAME="linux"
CPU_CORES=1
RAM_MB=0
GPU_NAME=""
GPU_VRAM_MB=0
CPU_MODEL=""

UNAME_S="$(uname -s 2>/dev/null || echo Linux)"

case "$UNAME_S" in
    Darwin)
        OS_NAME="macos"
        CPU_CORES="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 1)"
        CPU_MODEL="$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
        RAM_BYTES="$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0)"
        RAM_MB=$(( RAM_BYTES / 1024 / 1024 ))

        # Apple Silicon has unified memory, not a discrete VRAM figure — this
        # reports the chip name only in that case, VRAM stays 0 (caller
        # treats 0 as "unknown", not "no GPU").
        SP_OUT="$(/usr/sbin/system_profiler SPDisplaysDataType 2>/dev/null || true)"
        if [ -n "$SP_OUT" ]; then
            GPU_NAME="$(printf '%s\n' "$SP_OUT" | grep -m1 "Chipset Model:" | sed 's/.*Chipset Model:[[:space:]]*//')"
            VRAM_LINE="$(printf '%s\n' "$SP_OUT" | grep -m1 "VRAM (")"
            if [ -n "$VRAM_LINE" ]; then
                VRAM_NUM="$(printf '%s\n' "$VRAM_LINE" | sed 's/.*://; s/GB//i; s/MB//i' | tr -d '[:space:]')"
                if printf '%s' "$VRAM_NUM" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
                    GPU_VRAM_MB=$(awk -v n="$VRAM_NUM" 'BEGIN{printf "%d", n*1024}')
                fi
            fi
        fi
        ;;
    *)
        OS_NAME="linux"
        CPU_CORES="$(nproc 2>/dev/null || echo 1)"
        CPU_MODEL="$(awk -F: '/^model name/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
        if [ -r /proc/meminfo ]; then
            RAM_KB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
            RAM_MB=$(( RAM_KB / 1024 ))
        fi

        if command -v nvidia-smi >/dev/null 2>&1; then
            NVSMI_OUT="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)"
            if [ -n "$NVSMI_OUT" ]; then
                GPU_NAME="$(printf '%s' "$NVSMI_OUT" | cut -d',' -f1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
                GPU_VRAM_MB="$(printf '%s' "$NVSMI_OUT" | cut -d',' -f2 | tr -d '[:space:]')"
                [[ "$GPU_VRAM_MB" =~ ^[0-9]+$ ]] || GPU_VRAM_MB=0
            fi
        fi

        # AMD (amdgpu) — no vendor CLI tool needed, the kernel driver already
        # exposes real VRAM via sysfs. iGPUs and other drivers don't have this
        # file, so the first card that does is the discrete AMD GPU.
        if [ "$GPU_VRAM_MB" -eq 0 ] 2>/dev/null || [ -z "$GPU_VRAM_MB" ]; then
            for vram_file in /sys/class/drm/card*/device/mem_info_vram_total; do
                [ -f "$vram_file" ] || continue
                vram_bytes="$(cat "$vram_file" 2>/dev/null)"
                [[ "$vram_bytes" =~ ^[0-9]+$ ]] || continue
                [ "$vram_bytes" -eq 0 ] && continue
                GPU_VRAM_MB=$(( vram_bytes / 1024 / 1024 ))
                pci_slot="$(basename "$(readlink -f "$(dirname "$vram_file")")")"
                if command -v lspci >/dev/null 2>&1; then
                    GPU_NAME="$(lspci -s "$pci_slot" 2>/dev/null | sed 's/^[0-9a-f:.]*[[:space:]]*VGA compatible controller:[[:space:]]*//; s/^[0-9a-f:.]*[[:space:]]*Display controller:[[:space:]]*//')"
                fi
                break
            done
        fi
        ;;
esac

[[ "$CPU_CORES" =~ ^[0-9]+$ ]] || CPU_CORES=1
[[ "$RAM_MB" =~ ^[0-9]+$ ]] || RAM_MB=0

printf '{"ok":true,"os":"%s","cpu_cores":%d,"cpu_model":"%s","ram_mb":%d,"gpu_name":"%s","gpu_vram_mb":%d}\n' \
    "$OS_NAME" "$CPU_CORES" "$(json_escape "$CPU_MODEL")" "$RAM_MB" "$(json_escape "$GPU_NAME")" "$GPU_VRAM_MB"
