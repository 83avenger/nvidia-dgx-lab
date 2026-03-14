#!/bin/bash
# scripts/dpuflow/dpu-health-check.sh
# BlueField-3 DPU Health and Offload Validation
# Usage: ./dpu-health-check.sh

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "================================================"
echo "  NVIDIA BlueField-3 DPU — Health Check"
echo "  $(date)"
echo "================================================"

# 1. Detect BF3 via PCI
echo -e "\n${CYAN}[1/7]${NC} Detecting BlueField-3 DPU..."
BF3_DEVS=$(lspci | grep -i "BlueField\|MT42" || echo "")
if [ -n "$BF3_DEVS" ]; then
  echo -e "${GREEN}[PASS]${NC} BF3 DPU detected:"
  echo "$BF3_DEVS"
else
  echo -e "${YELLOW}[WARN]${NC} No BlueField DPU detected via PCI — checking rshim..."
fi

# 2. rshim connectivity
echo -e "\n${CYAN}[2/7]${NC} Checking rshim connection..."
if ls /dev/rshim* &>/dev/null 2>&1; then
  echo -e "${GREEN}[PASS]${NC} rshim device found: $(ls /dev/rshim*)"
else
  echo -e "${RED}[FAIL]${NC} No /dev/rshim* found — BF3 may not be connected or rshim driver not loaded"
  echo "  Try: modprobe rshim_pcie"
fi

# 3. OVS hardware offload status
echo -e "\n${CYAN}[3/7]${NC} Checking OVS hardware offload..."
if command -v ovs-vsctl &>/dev/null; then
  HW_OFFLOAD=$(ovs-vsctl get Open_vSwitch . other_config:hw-offload 2>/dev/null || echo "not-set")
  if [ "$HW_OFFLOAD" == '"true"' ]; then
    echo -e "${GREEN}[PASS]${NC} OVS hw-offload: ENABLED"
  else
    echo -e "${YELLOW}[WARN]${NC} OVS hw-offload: $HW_OFFLOAD (expected: true)"
    echo "  Fix: ovs-vsctl set Open_vSwitch . other_config:hw-offload=true"
  fi

  # Offloaded flow count
  OFFLOADED=$(ovs-appctl dpctl/dump-flows type=offloaded 2>/dev/null | wc -l || echo "0")
  echo -e "${CYAN}[INFO]${NC} Offloaded flows: $OFFLOADED"
else
  echo -e "${YELLOW}[WARN]${NC} OVS not installed on this host (may be on DPU Arm OS)"
fi

# 4. ConnectX-7 NIC status
echo -e "\n${CYAN}[4/7]${NC} Checking ConnectX-7 NIC interfaces..."
for iface in $(ls /sys/class/net/ | grep -E "^mlx|^enp.*mlx" 2>/dev/null || true); do
  STATE=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "unknown")
  SPEED=$(cat /sys/class/net/$iface/speed 2>/dev/null || echo "unknown")
  if [ "$STATE" == "up" ]; then
    echo -e "${GREEN}[UP]${NC}   $iface — Speed: ${SPEED}Mb/s"
  else
    echo -e "${RED}[DOWN]${NC} $iface — State: $STATE"
  fi
done

# 5. BlueField firmware version
echo -e "\n${CYAN}[5/7]${NC} Checking BlueField firmware..."
if command -v flint &>/dev/null; then
  for dev in /dev/mst/mt416*; do
    if [ -e "$dev" ]; then
      FW=$(flint -d "$dev" q 2>/dev/null | grep "FW Version" || echo "Unknown")
      echo -e "${GREEN}[INFO]${NC} $dev: $FW"
    fi
  done
elif command -v mlxfwmanager &>/dev/null; then
  mlxfwmanager --query 2>/dev/null | grep -E "(Device|FW)" || true
else
  echo -e "${YELLOW}[WARN]${NC} MFT tools not found — install mft package from NVIDIA"
fi

# 6. DOCA runtime check
echo -e "\n${CYAN}[6/7]${NC} Checking DOCA runtime..."
if dpkg -l 2>/dev/null | grep -q doca; then
  dpkg -l | grep doca | awk '{print "  " $2 " — " $3}'
  echo -e "${GREEN}[PASS]${NC} DOCA packages installed"
else
  echo -e "${YELLOW}[INFO]${NC} DOCA not installed on host (expected if running on DPU Arm OS side)"
fi

# 7. Summary
echo ""
echo "================================================"
echo "  DPU Health Check Complete"
echo "================================================"
echo ""
echo "Next steps if issues found:"
echo "  1. Check rshim: modprobe rshim_pcie"
echo "  2. Enable OVS offload: ovs-vsctl set Open_vSwitch . other_config:hw-offload=true"
echo "  3. Flash latest BF3 firmware: bfb-install --rshim /dev/rshim0 --image bf3-latest.bfb"
echo "  4. Check DOCA: apt install doca-sdk doca-runtime"
