#!/bin/bash
# scripts/infiniband/ib-fabric-check.sh
# Comprehensive InfiniBand fabric health check for DGX clusters
# Usage: ./ib-fabric-check.sh [--detailed]

set -euo pipefail

DETAILED=${1:-""}
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

echo ""
echo "=============================================="
echo "  NVIDIA DGX Cluster — IB Fabric Health Check"
echo "  $(date)"
echo "=============================================="

# 1. Check IB drivers loaded
echo ""
info "Checking IB kernel modules..."
for mod in ib_core ib_uverbs mlx5_core mlx5_ib rdma_cm; do
  if lsmod | grep -q "$mod"; then
    pass "Module $mod loaded"
  else
    fail "Module $mod NOT loaded — run: modprobe $mod"
  fi
done

# 2. IB port state
echo ""
info "Checking IB port states..."
if command -v ibstat &>/dev/null; then
  PORTS_ACTIVE=$(ibstat 2>/dev/null | grep -c "State: Active" || true)
  PORTS_DOWN=$(ibstat 2>/dev/null | grep -c "State: Down" || true)
  
  if [ "$PORTS_ACTIVE" -gt 0 ]; then
    pass "Active IB ports: $PORTS_ACTIVE"
  else
    fail "No active IB ports found"
  fi
  
  if [ "$PORTS_DOWN" -gt 0 ]; then
    warn "Ports in DOWN state: $PORTS_DOWN — check cables"
  fi
else
  warn "ibstat not found — install infiniband-diags"
fi

# 3. Subnet Manager check
echo ""
info "Checking Subnet Manager..."
if command -v sminfo &>/dev/null; then
  SM_OUTPUT=$(sminfo 2>/dev/null || echo "FAILED")
  if [[ "$SM_OUTPUT" == *"LID"* ]]; then
    pass "Subnet Manager active: $SM_OUTPUT"
  else
    fail "Subnet Manager not responding — check opensm/UFM"
  fi
fi

# 4. Error counters
echo ""
info "Checking port error counters..."
if command -v perfquery &>/dev/null; then
  SYM_ERRORS=$(perfquery -x -a 2>/dev/null | grep -oP 'SymbolErrors:\K\d+' | awk '{sum+=$1} END{print sum}' || echo "0")
  RCV_ERRORS=$(perfquery -x -a 2>/dev/null | grep -oP 'RcvErrors:\K\d+' | awk '{sum+=$1} END{print sum}' || echo "0")
  
  if [ "${SYM_ERRORS:-0}" -lt 1000 ]; then
    pass "Symbol errors: ${SYM_ERRORS:-0} (within threshold)"
  else
    warn "High symbol errors: ${SYM_ERRORS} — check cables and transceivers"
  fi
  
  if [ "${RCV_ERRORS:-0}" -lt 100 ]; then
    pass "Receive errors: ${RCV_ERRORS:-0} (within threshold)"
  else
    fail "High receive errors: ${RCV_ERRORS} — fabric issue detected"
  fi
fi

# 5. GPU Direct RDMA topology
echo ""
info "Checking GPU-NIC topology affinity..."
if command -v nvidia-smi &>/dev/null; then
  echo ""
  nvidia-smi topo -m 2>/dev/null || warn "nvidia-smi topo not available"
fi

# 6. RDMA device list
echo ""
info "RDMA devices detected:"
if command -v ibv_devinfo &>/dev/null; then
  ibv_devinfo 2>/dev/null | grep -E "(hca_id|port:|state:|link_layer)" || warn "No RDMA devices"
fi

# 7. Detailed fabric topology (optional)
if [ "$DETAILED" == "--detailed" ]; then
  echo ""
  info "Full fabric topology (ibnetdiscover):"
  ibnetdiscover 2>/dev/null || warn "ibnetdiscover failed"
fi

# 8. ConnectX FW versions
echo ""
info "ConnectX firmware versions:"
if command -v flint &>/dev/null; then
  for dev in /dev/mst/mt*pciconf*; do
    if [ -e "$dev" ]; then
      FW=$(flint -d "$dev" q 2>/dev/null | grep "FW Version" || echo "Unknown")
      echo "  $dev: $FW"
    fi
  done
else
  warn "flint not found — install MFT (NVIDIA Firmware Tools)"
fi

echo ""
echo "=============================================="
echo "  Health Check Complete"
echo "=============================================="
