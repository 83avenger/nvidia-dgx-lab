#!/bin/bash
# scripts/nccl/run-nccl-tests.sh
# Run a full NCCL test suite across DGX cluster
# Usage: ./run-nccl-tests.sh --nodes 4 --test all_reduce
# Requires: nccl-tests built, MPI installed, passwordless SSH between nodes

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Defaults
NODES=1
TEST="all_reduce"
HOSTFILE="/etc/mpi/hostfile"
NCCL_TESTS_DIR="${HOME}/nccl-tests"
MIN_BYTES="8"
MAX_BYTES="8G"
ITERS=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodes)       NODES="$2"; shift 2 ;;
    --test)        TEST="$2"; shift 2 ;;
    --hostfile)    HOSTFILE="$2"; shift 2 ;;
    --nccl-dir)    NCCL_TESTS_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

BINARY="${NCCL_TESTS_DIR}/build/${TEST}_perf"
GPUS_PER_NODE=8
TOTAL_GPUS=$((NODES * GPUS_PER_NODE))

echo ""
echo "========================================"
echo -e "  ${CYAN}NCCL Test Suite — DGX Cluster${NC}"
echo "  Test:       $TEST"
echo "  Nodes:      $NODES"
echo "  Total GPUs: $TOTAL_GPUS"
echo "  $(date)"
echo "========================================"

# --- Build nccl-tests if not present ---
if [ ! -f "$BINARY" ]; then
  echo -e "\n${YELLOW}[BUILD]${NC} Binary not found — cloning and building nccl-tests..."
  git clone https://github.com/NVIDIA/nccl-tests.git "$NCCL_TESTS_DIR"
  cd "$NCCL_TESTS_DIR"
  if command -v mpirun &>/dev/null; then
    make MPI=1 MPI_HOME="$(dirname $(which mpirun))/.." CUDA_HOME=/usr/local/cuda
  else
    make MPI=0 CUDA_HOME=/usr/local/cuda
  fi
  cd -
  echo -e "${GREEN}[OK]${NC} Build complete"
fi

# --- Single-node intra-GPU test (NVLink) ---
echo ""
echo -e "${CYAN}[TEST 1/3]${NC} Intra-node AllReduce (NVLink) — ${GPUS_PER_NODE} GPUs"
echo "----------------------------------------------"
NCCL_P2P_LEVEL=NVL \
NCCL_DEBUG=WARN \
"$BINARY" \
  -b "$MIN_BYTES" -e "$MAX_BYTES" -f 2 \
  -g "$GPUS_PER_NODE" \
  -n "$ITERS" \
  2>&1 | tee /tmp/nccl_intranode.log

INTRA_BW=$(grep "8589934592" /tmp/nccl_intranode.log | awk '{print $NF}' || echo "N/A")
echo -e "\n${GREEN}Intra-node busbw @ 8G: ${INTRA_BW} GB/s${NC}"

# --- Multi-node test via MPI ---
if [ "$NODES" -gt 1 ] && command -v mpirun &>/dev/null; then
  echo ""
  echo -e "${CYAN}[TEST 2/3]${NC} Inter-node AllReduce (InfiniBand NDR) — ${TOTAL_GPUS} GPUs across ${NODES} nodes"
  echo "----------------------------------------------"
  mpirun \
    --hostfile "$HOSTFILE" \
    -np "$TOTAL_GPUS" \
    --map-by ppr:${GPUS_PER_NODE}:node \
    --bind-to numa \
    -x NCCL_DEBUG=WARN \
    -x NCCL_IB_DISABLE=0 \
    -x NCCL_NET_GDR_LEVEL=5 \
    -x NCCL_IB_GID_INDEX=3 \
    -x NCCL_P2P_LEVEL=NVL \
    "$BINARY" \
      -b 1G -e "$MAX_BYTES" -f 2 \
      -g 1 -n "$ITERS" \
    2>&1 | tee /tmp/nccl_internode_ib.log

  INTER_BW=$(grep "8589934592" /tmp/nccl_internode_ib.log | awk '{print $NF}' || echo "N/A")
  echo -e "\n${GREEN}Inter-node (IB) busbw @ 8G: ${INTER_BW} GB/s${NC}"

  echo ""
  echo -e "${CYAN}[TEST 3/3]${NC} Inter-node AllReduce (RoCEv2 / Spectrum-X) — IB disabled"
  echo "----------------------------------------------"
  mpirun \
    --hostfile "$HOSTFILE" \
    -np "$TOTAL_GPUS" \
    --map-by ppr:${GPUS_PER_NODE}:node \
    -x NCCL_DEBUG=WARN \
    -x NCCL_IB_DISABLE=1 \
    -x NCCL_NET_GDR_LEVEL=5 \
    -x NCCL_SOCKET_IFNAME="^lo,docker" \
    "$BINARY" \
      -b 1G -e "$MAX_BYTES" -f 2 \
      -g 1 -n "$ITERS" \
    2>&1 | tee /tmp/nccl_internode_roce.log

  ROCE_BW=$(grep "8589934592" /tmp/nccl_internode_roce.log | awk '{print $NF}' || echo "N/A")
  echo -e "\n${GREEN}Inter-node (RoCEv2) busbw @ 8G: ${ROCE_BW} GB/s${NC}"
fi

# --- Summary Report ---
echo ""
echo "========================================"
echo "  NCCL Test Summary"
echo "========================================"
echo "  Intra-node NVLink busbw  : ${INTRA_BW:-N/A} GB/s  (target: >380)"
echo "  Inter-node IB NDR busbw  : ${INTER_BW:-N/A} GB/s  (target: >320)"
echo "  Inter-node RoCEv2 busbw  : ${ROCE_BW:-N/A} GB/s   (target: >280)"
echo ""
echo "  Logs: /tmp/nccl_*.log"
echo "========================================"
