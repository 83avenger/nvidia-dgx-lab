#!/bin/bash
# scripts/acceptance/full-acceptance-test.sh
# Orchestrates the full DGX cluster acceptance test suite
# Produces a signed-off report with pass/fail per test category
# Usage: ./full-acceptance-test.sh --cluster-size 8 --output /tmp/acceptance-report.txt

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

CLUSTER_SIZE=8
OUTPUT_FILE="/tmp/dgx-acceptance-$(date +%Y%m%d-%H%M%S).txt"
BURN_DURATION=1800     # 30 min
NCCL_NODES=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-size) CLUSTER_SIZE="$2"; shift 2 ;;
    --output)       OUTPUT_FILE="$2"; shift 2 ;;
    --burn-duration) BURN_DURATION="$2"; shift 2 ;;
    --nccl-nodes)   NCCL_NODES="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

declare -A RESULTS

pass()  { echo -e "${GREEN}[PASS]${NC} $1"; RESULTS["$1"]="PASS"; ((PASS_COUNT++)); }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; RESULTS["$1"]="FAIL"; ((FAIL_COUNT++)); }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; RESULTS["$1"]="WARN"; ((WARN_COUNT++)); }
section() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }

{
echo "================================================================"
echo "  NVIDIA DGX Cluster — Full Acceptance Test Report"
echo "  Cluster Size: ${CLUSTER_SIZE} nodes | Date: $(date)"
echo "  Hostname: $(hostname)"
echo "================================================================"

# ──────────────────────────────────────────────
section "PHASE 1: GPU Hardware"
# ──────────────────────────────────────────────

GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l || echo 0)
EXPECTED_GPUS=$((CLUSTER_SIZE * 8))
if [ "$GPU_COUNT" -ge 8 ]; then
  pass "GPU count: $GPU_COUNT detected (expected ≥8 on this node)"
else
  fail "GPU count: only $GPU_COUNT GPUs detected"
fi

DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
if [ -n "$DRIVER_VER" ]; then
  pass "NVIDIA driver: $DRIVER_VER"
else
  fail "NVIDIA driver not responding"
fi

FM_STATUS=$(systemctl is-active nvidia-fabricmanager 2>/dev/null || echo "inactive")
if [ "$FM_STATUS" == "active" ]; then
  pass "Fabric Manager: active"
else
  fail "Fabric Manager: $FM_STATUS"
fi

XID_ERRORS=$(nvidia-smi | grep -c "Xid\|xid" 2>/dev/null || echo 0)
if [ "$XID_ERRORS" -eq 0 ]; then
  pass "XID errors: none at baseline"
else
  fail "XID errors detected: $XID_ERRORS — investigate before proceeding"
fi

# ──────────────────────────────────────────────
section "PHASE 2: InfiniBand Fabric"
# ──────────────────────────────────────────────

IB_ACTIVE=$(ibstat 2>/dev/null | grep -c "State: Active" || echo 0)
if [ "$IB_ACTIVE" -gt 0 ]; then
  pass "IB active ports: $IB_ACTIVE"
else
  fail "No active IB ports found"
fi

SM_STATUS=$(sminfo 2>/dev/null | grep -c "LID" || echo 0)
if [ "$SM_STATUS" -gt 0 ]; then
  pass "Subnet Manager: responding"
else
  fail "Subnet Manager: not responding"
fi

IB_NODES=$(ibnetdiscover 2>/dev/null | grep -c "Ca" || echo 0)
if [ "$IB_NODES" -ge "$CLUSTER_SIZE" ]; then
  pass "IB fabric nodes: $IB_NODES discovered (expected: $CLUSTER_SIZE)"
else
  warn "IB fabric nodes: $IB_NODES (expected: $CLUSTER_SIZE) — check cabling"
fi

SYM_ERR=$(perfquery -x -a 2>/dev/null | grep -oP 'SymbolErrors:\K\d+' | awk '{s+=$1}END{print s+0}')
if [ "${SYM_ERR:-0}" -lt 1000 ]; then
  pass "IB symbol errors: ${SYM_ERR:-0} (threshold: 1000)"
else
  fail "IB symbol errors: $SYM_ERR — check cables"
fi

# ──────────────────────────────────────────────
section "PHASE 3: GPU Direct RDMA"
# ──────────────────────────────────────────────

PEERMEM=$(lsmod | grep -c nvidia_peermem || echo 0)
if [ "$PEERMEM" -gt 0 ]; then
  pass "nvidia-peermem: loaded"
else
  fail "nvidia-peermem: NOT loaded — GPU Direct RDMA disabled"
fi

TOPO=$(nvidia-smi topo -m 2>/dev/null | grep -c "NV\|PIX" || echo 0)
if [ "$TOPO" -gt 0 ]; then
  pass "GPU topology: NVLink/PCIe paths detected"
else
  warn "GPU topology: could not verify NVLink paths"
fi

# ──────────────────────────────────────────────
section "PHASE 4: NCCL Bandwidth"
# ──────────────────────────────────────────────

if [ -f "${HOME}/nccl-tests/build/all_reduce_perf" ]; then
  echo "[INFO] Running NCCL AllReduce intra-node (NVLink)..."
  NCCL_OUT=$(NCCL_DEBUG=WARN \
    "${HOME}/nccl-tests/build/all_reduce_perf" -b 1G -e 8G -f 2 -g 8 -n 10 2>&1 || true)
  NCCL_BW=$(echo "$NCCL_OUT" | grep "8589934592" | awk '{print $NF}' || echo "0")
  if awk "BEGIN{exit !($NCCL_BW >= 350)}"; then
    pass "NCCL intra-node busbw: ${NCCL_BW} GB/s (threshold: 350)"
  else
    fail "NCCL intra-node busbw: ${NCCL_BW} GB/s — below 350 GB/s target"
  fi
else
  warn "NCCL tests not built — skipping (run: ./scripts/nccl/run-nccl-tests.sh)"
fi

# ──────────────────────────────────────────────
section "PHASE 5: GPU Thermal Stability"
# ──────────────────────────────────────────────

if [ -f "${HOME}/gpu-burn/gpu_burn" ]; then
  echo "[INFO] Running GPU burn for 120s (quick acceptance pass)..."
  BURN_OUT=$("${HOME}/gpu-burn/gpu_burn" -d 120 2>&1 || echo "FAILED")
  if echo "$BURN_OUT" | grep -q "100\.0%"; then
    pass "GPU burn 120s: all GPUs at 100% — no thermal failures"
  else
    fail "GPU burn 120s: errors or below 100% — check cooling"
  fi
  MAX_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | sort -n | tail -1)
  if [ "${MAX_TEMP:-0}" -lt 85 ]; then
    pass "Peak temperature: ${MAX_TEMP}°C (threshold: 85°C)"
  else
    fail "Peak temperature: ${MAX_TEMP}°C — EXCEEDS 85°C threshold"
  fi
else
  warn "gpu-burn not built — skipping thermal test (run: ./scripts/gpu-burn/gpu-burn-stress.sh)"
fi

# ──────────────────────────────────────────────
section "PHASE 6: Kubernetes & Run:ai"
# ──────────────────────────────────────────────

K8S=$(kubectl cluster-info 2>/dev/null | grep -c "running" || echo 0)
if [ "$K8S" -gt 0 ]; then
  pass "Kubernetes cluster: reachable"
else
  warn "Kubernetes: not reachable from this node"
fi

GPU_OP=$(kubectl get pods -n gpu-operator 2>/dev/null | grep -c "Running" || echo 0)
if [ "$GPU_OP" -gt 3 ]; then
  pass "GPU Operator: $GPU_OP pods running"
else
  warn "GPU Operator: $GPU_OP pods running (expected >3)"
fi

RUNAI=$(runai cluster info 2>/dev/null | grep -c "Connected\|Ready" || echo 0)
if [ "$RUNAI" -gt 0 ]; then
  pass "Run:ai: cluster connected"
else
  warn "Run:ai: not connected or CLI not configured"
fi

# ──────────────────────────────────────────────
section "SUMMARY"
# ──────────────────────────────────────────────

echo ""
echo "  PASS: $PASS_COUNT"
echo "  WARN: $WARN_COUNT"
echo "  FAIL: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}  VERDICT: CLUSTER ACCEPTED ✅${NC}"
elif [ "$FAIL_COUNT" -le 2 ]; then
  echo -e "${YELLOW}${BOLD}  VERDICT: CONDITIONAL ACCEPTANCE ⚠️  — $FAIL_COUNT items require resolution${NC}"
else
  echo -e "${RED}${BOLD}  VERDICT: NOT ACCEPTED ❌ — $FAIL_COUNT critical failures${NC}"
fi

echo ""
echo "  Report saved: $OUTPUT_FILE"
echo "================================================================"

} | tee "$OUTPUT_FILE"

chmod +x "$0"
