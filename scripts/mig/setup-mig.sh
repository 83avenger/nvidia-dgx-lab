#!/bin/bash
# scripts/mig/setup-mig.sh
# MIG profile setup for NVIDIA A100 / H100 DGX
# Usage: sudo ./setup-mig.sh --profile 3g.20gb --gpu-ids 0,1,2,3

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults
PROFILE="3g.20gb"
GPU_IDS="all"

# MIG Profile ID mapping (A100 / H100)
declare -A PROFILE_ID_MAP=(
  ["1g.10gb"]=19
  ["2g.20gb"]=14
  ["3g.20gb"]=9
  ["4g.40gb"]=5
  ["7g.80gb"]=0
)

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --gpu-ids) GPU_IDS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

PROFILE_ID="${PROFILE_ID_MAP[$PROFILE]:-}"
if [ -z "$PROFILE_ID" ]; then
  echo -e "${RED}[ERROR]${NC} Invalid profile: $PROFILE"
  echo "Valid profiles: ${!PROFILE_ID_MAP[*]}"
  exit 1
fi

echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}  NVIDIA MIG Setup — Profile: $PROFILE${NC}"
echo -e "${CYAN}================================================${NC}"

# Step 1: Check prerequisites
echo -e "\n${CYAN}[1/5]${NC} Checking prerequisites..."
if ! command -v nvidia-smi &>/dev/null; then
  echo -e "${RED}[FAIL]${NC} nvidia-smi not found. Install NVIDIA drivers first."
  exit 1
fi
echo -e "${GREEN}[PASS]${NC} nvidia-smi found"

# Check Fabric Manager (required for DGX NVSwitch)
if systemctl is-active --quiet nvidia-fabricmanager 2>/dev/null; then
  echo -e "${GREEN}[PASS]${NC} nvidia-fabricmanager running"
else
  echo -e "${YELLOW}[WARN]${NC} nvidia-fabricmanager not running — required for DGX NVSwitch"
fi

# Step 2: Identify GPUs
echo -e "\n${CYAN}[2/5]${NC} Identifying GPUs..."
nvidia-smi -L
GPU_COUNT=$(nvidia-smi -L | wc -l)
echo -e "${GREEN}[INFO]${NC} Total GPUs detected: $GPU_COUNT"

# Build GPU list
if [ "$GPU_IDS" == "all" ]; then
  GPU_LIST=($(seq 0 $((GPU_COUNT-1))))
else
  IFS=',' read -ra GPU_LIST <<< "$GPU_IDS"
fi

echo -e "${GREEN}[INFO]${NC} Target GPUs: ${GPU_LIST[*]}"

# Step 3: Clean existing MIG instances
echo -e "\n${CYAN}[3/5]${NC} Cleaning existing MIG configuration..."
nvidia-smi mig -dci 2>/dev/null && echo -e "${GREEN}[OK]${NC} Compute instances deleted" || true
nvidia-smi mig -dgi 2>/dev/null && echo -e "${GREEN}[OK]${NC} GPU instances deleted" || true

# Step 4: Enable MIG mode
echo -e "\n${CYAN}[4/5]${NC} Enabling MIG mode..."
for GPU in "${GPU_LIST[@]}"; do
  nvidia-smi -i "$GPU" -mig 1
  echo -e "${GREEN}[OK]${NC} GPU $GPU: MIG enabled"
done

echo "Waiting 5s for MIG mode to settle..."
sleep 5

# Step 5: Create MIG instances
echo -e "\n${CYAN}[5/5]${NC} Creating MIG instances (profile: $PROFILE, ID: $PROFILE_ID)..."
for GPU in "${GPU_LIST[@]}"; do
  nvidia-smi -i "$GPU" mig -cgi "$PROFILE_ID" -C
  echo -e "${GREEN}[OK]${NC} GPU $GPU: $PROFILE instances created"
done

# Summary
echo -e "\n${CYAN}================================================${NC}"
echo -e "${CYAN}  MIG Configuration Complete${NC}"
echo -e "${CYAN}================================================${NC}"
echo ""
echo "MIG GPU Instances:"
nvidia-smi mig -lgi
echo ""
echo "MIG Compute Instances:"
nvidia-smi mig -lci
echo ""
echo -e "${GREEN}[DONE]${NC} MIG setup complete. Profile: $PROFILE on GPUs: ${GPU_LIST[*]}"
