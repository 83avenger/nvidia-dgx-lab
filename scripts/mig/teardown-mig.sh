#!/bin/bash
# scripts/mig/teardown-mig.sh
# Safely disable MIG on all or specified GPUs
# Usage: sudo ./teardown-mig.sh [--gpu-ids 0,1,2,3]

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

GPU_IDS=${1:-"all"}

echo ""
echo "================================================"
echo "  NVIDIA MIG Teardown"
echo "  $(date)"
echo "================================================"

echo -e "\n${YELLOW}[WARN]${NC} This will destroy all MIG instances and disable MIG mode."
echo -e "${YELLOW}[WARN]${NC} Any running GPU workloads WILL be interrupted."
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo -e "\n${CYAN}[1/4]${NC} Killing active GPU processes..."
nvidia-smi --kill-active-processes 2>/dev/null || true
sleep 2

echo -e "\n${CYAN}[2/4]${NC} Destroying MIG Compute Instances..."
nvidia-smi mig -dci 2>/dev/null && echo -e "${GREEN}[OK]${NC} Compute instances destroyed" || echo -e "${YELLOW}[SKIP]${NC} No compute instances found"

echo -e "\n${CYAN}[3/4]${NC} Destroying MIG GPU Instances..."
nvidia-smi mig -dgi 2>/dev/null && echo -e "${GREEN}[OK]${NC} GPU instances destroyed" || echo -e "${YELLOW}[SKIP]${NC} No GPU instances found"

echo -e "\n${CYAN}[4/4]${NC} Disabling MIG mode..."
if [ "$GPU_IDS" == "all" ]; then
  nvidia-smi -mig 0
  echo -e "${GREEN}[OK]${NC} MIG disabled on all GPUs"
else
  IFS=',' read -ra GPUS <<< "$GPU_IDS"
  for GPU in "${GPUS[@]}"; do
    nvidia-smi -i "$GPU" -mig 0
    echo -e "${GREEN}[OK]${NC} GPU $GPU: MIG disabled"
  done
fi

echo ""
echo "=== GPU Status (Full Mode) ==="
nvidia-smi --query-gpu=index,name,mig.mode.current,memory.free --format=csv,noheader

echo ""
echo -e "${GREEN}[DONE]${NC} MIG teardown complete. All GPUs restored to full GPU mode."
