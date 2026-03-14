#!/bin/bash
# tests/rdma/rdma-bw-test.sh
# RDMA bandwidth and latency tests using perftest suite
# Tests both IB and RoCEv2 transports
# Usage: ./rdma-bw-test.sh --server <ip> --device mlx5_0
# On server node: ./rdma-bw-test.sh --mode server --device mlx5_0

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

MODE="client"
SERVER_IP=""
DEVICE="mlx5_0"
PORT=18515

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)   MODE="$2"; shift 2 ;;
    --server) SERVER_IP="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo ""
echo "============================================"
echo -e "  ${CYAN}RDMA Bandwidth & Latency Test${NC}"
echo "  Mode:   $MODE"
echo "  Device: $DEVICE"
echo "  $(date)"
echo "============================================"

# Check perftest is installed
if ! command -v ib_write_bw &>/dev/null; then
  echo -e "${YELLOW}Installing perftest...${NC}"
  apt-get install -y perftest
fi

if [ "$MODE" == "server" ]; then
  echo -e "\n${CYAN}[SERVER MODE]${NC} Waiting for client connections..."
  echo "Bandwidth test server:"
  ib_write_bw -d "$DEVICE" -p "$PORT" --report_gbits &
  BW_PID=$!

  echo "Latency test server:"
  ib_write_lat -d "$DEVICE" -p $((PORT+1)) &
  LAT_PID=$!

  echo -e "${GREEN}Servers listening on $DEVICE${NC}"
  echo "Run on client: $0 --mode client --server <this-ip> --device $DEVICE"
  wait

else
  # Client mode
  if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}[ERROR]${NC} --server <ip> required in client mode"
    exit 1
  fi

  # --- Write BW ---
  echo -e "\n${CYAN}[TEST 1/4]${NC} RDMA Write Bandwidth (ib_write_bw)"
  ib_write_bw \
    -d "$DEVICE" \
    -p "$PORT" \
    --report_gbits \
    -s 65536 \
    -n 1000 \
    "$SERVER_IP" 2>&1 | tee /tmp/rdma_write_bw.log
  WRITE_BW=$(grep "65536" /tmp/rdma_write_bw.log | awk '{print $4}' | tail -1)
  echo -e "\n${GREEN}Write BW: ${WRITE_BW:-N/A} Gb/s${NC}"

  # --- Read BW ---
  echo -e "\n${CYAN}[TEST 2/4]${NC} RDMA Read Bandwidth (ib_read_bw)"
  ib_read_bw \
    -d "$DEVICE" \
    -p $((PORT+2)) \
    --report_gbits \
    -s 65536 \
    -n 1000 \
    "$SERVER_IP" 2>&1 | tee /tmp/rdma_read_bw.log
  READ_BW=$(grep "65536" /tmp/rdma_read_bw.log | awk '{print $4}' | tail -1)
  echo -e "\n${GREEN}Read BW: ${READ_BW:-N/A} Gb/s${NC}"

  # --- Write Latency ---
  echo -e "\n${CYAN}[TEST 3/4]${NC} RDMA Write Latency (ib_write_lat)"
  ib_write_lat \
    -d "$DEVICE" \
    -p $((PORT+1)) \
    -n 1000 \
    "$SERVER_IP" 2>&1 | tee /tmp/rdma_write_lat.log
  WRITE_LAT=$(grep "2" /tmp/rdma_write_lat.log | awk '{print $5}' | tail -1)
  echo -e "\n${GREEN}Write Latency (avg): ${WRITE_LAT:-N/A} µs${NC}"

  # --- Send BW (GPU Direct) ---
  echo -e "\n${CYAN}[TEST 4/4]${NC} GPU Direct RDMA Send BW (ib_send_bw + GDR)"
  ib_send_bw \
    -d "$DEVICE" \
    -p $((PORT+3)) \
    --report_gbits \
    --use_cuda=0 \
    -n 500 \
    "$SERVER_IP" 2>&1 | tee /tmp/rdma_gdr_bw.log || true
  GDR_BW=$(grep "65536\|131072" /tmp/rdma_gdr_bw.log | awk '{print $4}' | tail -1 || echo "N/A")
  echo -e "\n${GREEN}GPU Direct RDMA BW: ${GDR_BW:-N/A} Gb/s${NC}"

  # --- Summary ---
  echo ""
  echo "============================================"
  echo "  RDMA Test Results vs Targets"
  echo "============================================"
  printf "  %-25s %10s  %10s\n" "Test" "Result" "Target"
  printf "  %-25s %10s  %10s\n" "-------------------------" "----------" "----------"
  printf "  %-25s %10s  %10s\n" "Write BW"   "${WRITE_BW:-N/A} Gb/s" "~380 Gb/s"
  printf "  %-25s %10s  %10s\n" "Read BW"    "${READ_BW:-N/A} Gb/s"  "~380 Gb/s"
  printf "  %-25s %10s  %10s\n" "Write Lat"  "${WRITE_LAT:-N/A} µs"  "< 2 µs"
  printf "  %-25s %10s  %10s\n" "GPU Direct" "${GDR_BW:-N/A} Gb/s"   "~350 Gb/s"
  echo ""
  echo "  Logs: /tmp/rdma_*.log"
  echo "============================================"
fi
