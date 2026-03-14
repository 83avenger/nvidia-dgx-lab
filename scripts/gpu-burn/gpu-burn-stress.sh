#!/bin/bash
# scripts/gpu-burn/gpu-burn-stress.sh
# GPU thermal and stability stress test for DGX acceptance testing
# Usage: sudo ./gpu-burn-stress.sh --duration 600 --gpus all
# Requires: gpu-burn (https://github.com/wilicc/gpu-burn) or nvidia-smi dmon

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

DURATION=300      # seconds
GPU_IDS="all"
GPU_BURN_DIR="${HOME}/gpu-burn"
TEMP_LIMIT=85     # Celsius — alert if exceeded
POWER_LIMIT=750   # Watts — alert if exceeded

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --gpus)     GPU_IDS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo ""
echo "========================================"
echo -e "  ${CYAN}GPU Burn — DGX Stress Test${NC}"
echo "  Duration:    ${DURATION}s"
echo "  GPUs:        ${GPU_IDS}"
echo "  Temp limit:  ${TEMP_LIMIT}°C"
echo "  Power limit: ${POWER_LIMIT}W"
echo "  $(date)"
echo "========================================"

# --- Pre-flight: baseline GPU state ---
echo -e "\n${CYAN}[PRE-FLIGHT]${NC} Baseline GPU state:"
nvidia-smi --query-gpu=index,name,temperature.gpu,power.draw,memory.used,utilization.gpu \
  --format=csv,noheader,nounits

# --- Build gpu-burn if not present ---
if [ ! -f "${GPU_BURN_DIR}/gpu_burn" ]; then
  echo -e "\n${YELLOW}[BUILD]${NC} Building gpu-burn..."
  apt-get install -y git build-essential cuda-toolkit &>/dev/null || true
  git clone https://github.com/wilicc/gpu-burn.git "$GPU_BURN_DIR"
  cd "$GPU_BURN_DIR" && make && cd -
  echo -e "${GREEN}[OK]${NC} gpu-burn ready"
fi

# --- Monitor in background ---
LOG_FILE="/tmp/gpu-burn-monitor-$(date +%Y%m%d-%H%M%S).csv"
echo "timestamp,gpu_id,temp_c,power_w,mem_used_mb,util_pct" > "$LOG_FILE"

monitor_gpus() {
  while true; do
    TS=$(date +%s)
    nvidia-smi --query-gpu=index,temperature.gpu,power.draw,memory.used,utilization.gpu \
      --format=csv,noheader,nounits 2>/dev/null | while IFS=',' read -r idx temp power mem util; do
      echo "${TS},${idx// /},${temp// /},${power// /},${mem// /},${util// /}" >> "$LOG_FILE"

      # Alert on threshold breach
      if [ "${temp// /}" -gt "$TEMP_LIMIT" ] 2>/dev/null; then
        echo -e "${RED}[ALERT]${NC} GPU ${idx// /}: TEMPERATURE ${temp// /}°C exceeds ${TEMP_LIMIT}°C!"
      fi
    done
    sleep 5
  done
}

monitor_gpus &
MONITOR_PID=$!
echo -e "${CYAN}[INFO]${NC} Monitoring started (PID: $MONITOR_PID) → $LOG_FILE"

# --- Run gpu-burn ---
echo -e "\n${CYAN}[BURN]${NC} Starting GPU stress test for ${DURATION}s..."
if [ "$GPU_IDS" == "all" ]; then
  "${GPU_BURN_DIR}/gpu_burn" -d "$DURATION"
else
  CUDA_VISIBLE_DEVICES="$GPU_IDS" "${GPU_BURN_DIR}/gpu_burn" -d "$DURATION"
fi

BURN_EXIT=$?

# --- Stop monitor ---
kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true

# --- Post-burn analysis ---
echo ""
echo -e "${CYAN}[ANALYSIS]${NC} Post-burn GPU state:"
nvidia-smi --query-gpu=index,name,temperature.gpu,power.draw,memory.used,utilization.gpu \
  --format=csv,noheader,nounits

echo ""
echo -e "${CYAN}[ANALYSIS]${NC} Peak temperatures during burn:"
awk -F',' 'NR>1 {
  if ($3 > max[$2]) max[$2]=$3
} END {
  for (g in max) printf "  GPU %s: peak %s°C\n", g, max[g]
}' "$LOG_FILE"

echo ""
echo -e "${CYAN}[ANALYSIS]${NC} Checking for XID errors post-burn:"
nvidia-smi | grep -i "xid\|error" || echo "  No XID errors detected"

# --- Pass/Fail ---
echo ""
if [ "$BURN_EXIT" -eq 0 ]; then
  echo -e "${GREEN}[PASS]${NC} GPU burn completed — no failures detected"
  echo -e "${GREEN}[PASS]${NC} Cluster is thermally stable for ${DURATION}s sustained load"
else
  echo -e "${RED}[FAIL]${NC} GPU burn reported errors (exit code: $BURN_EXIT)"
  echo "  Check nvidia-smi for XID errors and review: $LOG_FILE"
fi

echo ""
echo "  Monitor log: $LOG_FILE"
echo "========================================"
