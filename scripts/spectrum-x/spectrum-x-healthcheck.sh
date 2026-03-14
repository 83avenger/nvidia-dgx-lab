#!/bin/bash
# scripts/spectrum-x/spectrum-x-healthcheck.sh
# Spectrum-X RoCEv2 fabric health validation
# Run on each compute node connected to Spectrum-4 switches
# Usage: ./spectrum-x-healthcheck.sh [--interface mlx5_0]

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

IFACE=${2:-"mlx5_0"}
PFC_PRIORITY=3        # PFC priority mapped to DSCP 26 (RoCEv2)
ROCE_DSCP=26

echo ""
echo "================================================"
echo "  NVIDIA Spectrum-X RoCEv2 — Health Check"
echo "  Interface: $IFACE | $(date)"
echo "================================================"

# 1. RDMA device detection
echo -e "\n${CYAN}[1/8]${NC} Detecting RDMA / ConnectX-7 devices..."
if command -v ibv_devinfo &>/dev/null; then
  RDMA_DEVS=$(ibv_devinfo 2>/dev/null | grep "hca_id" | awk '{print $2}' || echo "")
  if [ -n "$RDMA_DEVS" ]; then
    echo -e "${GREEN}[PASS]${NC} RDMA devices: $RDMA_DEVS"
  else
    echo -e "${RED}[FAIL]${NC} No RDMA devices found"
    exit 1
  fi
else
  echo -e "${YELLOW}[WARN]${NC} ibv_devinfo not found — install libibverbs-utils"
fi

# 2. RoCE mode check
echo -e "\n${CYAN}[2/8]${NC} Checking RoCE mode (expect RoCEv2)..."
if command -v cma_roce_mode &>/dev/null; then
  ROCE_MODE=$(cma_roce_mode -d "$IFACE" -p 1 2>/dev/null || echo "unknown")
  if echo "$ROCE_MODE" | grep -q "2"; then
    echo -e "${GREEN}[PASS]${NC} RoCEv2 mode confirmed on $IFACE"
  else
    echo -e "${YELLOW}[WARN]${NC} RoCE mode: $ROCE_MODE — expected RoCEv2 (mode 2)"
    echo "  Fix: cma_roce_mode -d $IFACE -p 1 -m 2"
  fi
else
  echo -e "${YELLOW}[INFO]${NC} cma_roce_mode not available — check rdma-core install"
fi

# 3. DSCP / TOS mapping
echo -e "\n${CYAN}[3/8]${NC} Checking DSCP-to-TC mapping (DSCP 26 → TC3)..."
if command -v mlxconfig &>/dev/null; then
  TCLASS=$(mlxconfig -d /dev/mst/mt4129_pciconf0 q 2>/dev/null | grep TCLASS | awk '{print $2}' || echo "N/A")
  echo -e "${CYAN}[INFO]${NC} Current TCLASS: $TCLASS (expected 106 for DSCP 26)"
fi

# 4. PFC lossless check
echo -e "\n${CYAN}[4/8]${NC} Checking PFC (Priority Flow Control) status..."
for NIC in $(ls /sys/class/net/ | grep -E "^enp|^mlx" 2>/dev/null || true); do
  PFC_STATE=$(cat /sys/class/net/$NIC/qos/pfc_enabled 2>/dev/null || echo "N/A")
  if [ "$PFC_STATE" == "1" ] || [ "$PFC_STATE" == "true" ]; then
    echo -e "${GREEN}[PASS]${NC} PFC enabled on $NIC"
  else
    echo -e "${YELLOW}[WARN]${NC} PFC state on $NIC: $PFC_STATE"
  fi
done

# 5. MTU check (RoCEv2 should use 4200+ for large messages)
echo -e "\n${CYAN}[5/8]${NC} Checking interface MTU..."
for NIC in $(ls /sys/class/net/ | grep -E "^enp|^mlx" 2>/dev/null || true); do
  MTU=$(cat /sys/class/net/$NIC/mtu 2>/dev/null || echo "0")
  if [ "$MTU" -ge 4200 ] 2>/dev/null; then
    echo -e "${GREEN}[PASS]${NC} $NIC MTU: $MTU (jumbo frames OK)"
  else
    echo -e "${YELLOW}[WARN]${NC} $NIC MTU: $MTU — recommend ≥4200 for RoCEv2"
    echo "  Fix: ip link set dev $NIC mtu 4200"
  fi
done

# 6. ECN check
echo -e "\n${CYAN}[6/8]${NC} Checking ECN (Explicit Congestion Notification)..."
ECN_STATE=$(cat /proc/sys/net/ipv4/tcp_ecn 2>/dev/null || echo "unknown")
if [ "$ECN_STATE" == "1" ] || [ "$ECN_STATE" == "2" ]; then
  echo -e "${GREEN}[PASS]${NC} ECN enabled (mode: $ECN_STATE)"
else
  echo -e "${YELLOW}[WARN]${NC} ECN disabled (value: $ECN_STATE)"
  echo "  Fix: sysctl -w net.ipv4.tcp_ecn=1"
fi

# 7. RDMA bandwidth test (requires peer)
echo -e "\n${CYAN}[7/8]${NC} RDMA bandwidth test availability..."
if command -v ib_write_bw &>/dev/null; then
  echo -e "${GREEN}[INFO]${NC} perftest tools available"
  echo "  Run on server: ib_write_bw -d $IFACE --report_gbits"
  echo "  Run on client: ib_write_bw -d $IFACE <server-ip> --report_gbits"
else
  echo -e "${YELLOW}[WARN]${NC} perftest not installed"
  echo "  Install: apt install perftest"
fi

# 8. ConnectX-7 firmware
echo -e "\n${CYAN}[8/8]${NC} ConnectX-7 firmware version..."
if command -v mlxfwmanager &>/dev/null; then
  mlxfwmanager --query 2>/dev/null | grep -E "Device|FW|PSID" || true
elif command -v flint &>/dev/null; then
  for dev in /dev/mst/mt*; do
    [ -e "$dev" ] || continue
    flint -d "$dev" q 2>/dev/null | grep -E "FW Version|PSID" || true
  done
else
  echo -e "${YELLOW}[WARN]${NC} MFT not installed — download from network.nvidia.com"
fi

echo ""
echo "================================================"
echo "  Spectrum-X Health Check Complete"
echo "================================================"
echo ""
echo "Quick fix commands:"
echo "  RoCEv2 mode:  cma_roce_mode -d $IFACE -p 1 -m 2"
echo "  DSCP mark:    cma_roce_tos -d $IFACE -p 1 -t 106"
echo "  MTU jumbo:    ip link set dev <NIC> mtu 4200"
echo "  ECN on:       sysctl -w net.ipv4.tcp_ecn=1"
