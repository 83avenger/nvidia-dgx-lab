# 04 — MIG Profiles: A100 / H100 Multi-Instance GPU

## MIG Architecture Concepts

| Term | Meaning |
|------|---------|
| **GI** | GPU Instance — hardware partition (SM + L2 + HBM) |
| **CI** | Compute Instance — within a GI, shares memory, splits SMs |
| **MIG Profile** | Named combination of GI size, e.g. `3g.20gb` |
| **Placement** | GPU slice position (0–6) |

---

## A100 / H100 MIG Profiles

| Profile | SMs | HBM | NVLink | Max per GPU |
|---------|-----|-----|--------|------------|
| `1g.10gb` | 14 | 10 GB | ❌ | 7 |
| `2g.20gb` | 28 | 20 GB | ❌ | 3 |
| `3g.20gb` | 42 | 20 GB | ❌ | 2 |
| `4g.40gb` | 56 | 40 GB | ❌ | 1 |
| `7g.80gb` | 98 | 80 GB | ✅ | 1 |

> H100 also has `1g.10gb+me` (Media Extensions) for video inferencing.

---

## Enable MIG Mode

```bash
# Enable MIG on all GPUs
sudo nvidia-smi -mig 1

# Enable on specific GPU (e.g., GPU 0)
sudo nvidia-smi -i 0 -mig 1

# Verify
nvidia-smi --query-gpu=mig.mode.current --format=csv
```

---

## Create MIG Instances (Manual)

```bash
# Create 3g.20gb profile on GPU 0
sudo nvidia-smi mig -cgi 9,9 -C   # Two 3g.20gb (profile ID 9)

# Create 7g.80gb (full GPU) on GPU 1
sudo nvidia-smi -i 1 mig -cgi 0 -C

# List all MIG instances
nvidia-smi mig -lgi
nvidia-smi mig -lci

# Delete all instances
sudo nvidia-smi mig -dci
sudo nvidia-smi mig -dgi
```

---

## MIG Setup Script: setup-mig.sh

```bash
#!/bin/bash
# scripts/mig/setup-mig.sh
# Usage: ./setup-mig.sh --profile 3g.20gb --gpu-ids 0,1,2,3

set -euo pipefail

PROFILE=${1:-"3g.20gb"}
GPU_IDS=${2:-"0"}

declare -A PROFILE_ID_MAP=(
  ["1g.10gb"]=19
  ["2g.20gb"]=14
  ["3g.20gb"]=9
  ["4g.40gb"]=5
  ["7g.80gb"]=0
)

PROFILE_ID="${PROFILE_ID_MAP[$PROFILE]}"

echo "[+] Enabling MIG mode on GPUs: $GPU_IDS"
IFS=',' read -ra GPUS <<< "$GPU_IDS"
for GPU in "${GPUS[@]}"; do
  nvidia-smi -i "$GPU" -mig 1
  echo "[+] GPU $GPU MIG enabled"
done

echo "[+] Rebooting GPU driver context (if needed)..."
# systemctl restart nvidia-fabricmanager  # Uncomment for DGX

echo "[+] Creating MIG instances with profile: $PROFILE (ID: $PROFILE_ID)"
for GPU in "${GPUS[@]}"; do
  nvidia-smi -i "$GPU" mig -cgi "$PROFILE_ID" -C
  echo "[+] GPU $GPU: $PROFILE instance created"
done

echo ""
echo "=== MIG Instance Summary ==="
nvidia-smi mig -lgi
nvidia-smi mig -lci
```

---

## MIG Profile YAML (Kubernetes / Run:ai)

```yaml
# configs/mig/mig-3g20gb-profile.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mig-parted-config
  namespace: gpu-operator
data:
  config.yaml: |
    version: v1
    mig-configs:
      all-3g.20gb:
        - devices: all
          mig-enabled: true
          mig-devices:
            3g.20gb: 2
      all-1g.10gb:
        - devices: all
          mig-enabled: true
          mig-devices:
            1g.10gb: 7
      mixed:
        - devices: [0,1,2,3]
          mig-enabled: true
          mig-devices:
            3g.20gb: 2
        - devices: [4,5,6,7]
          mig-enabled: true
          mig-devices:
            1g.10gb: 7
```

---

## Run:ai MIG Scheduling

```bash
# Submit job requesting 1 MIG slice (3g.20gb)
runai submit mig-job \
  --image nvcr.io/nvidia/cuda:12.0-base \
  --gpu 0.5 \                    # fractional = MIG
  --gpu-memory 20Gi \
  -- nvidia-smi

# Submit with explicit MIG profile annotation
kubectl annotate pod mig-job \
  nvidia.com/mig.config=3g.20gb
```

---

## Disable MIG (Teardown)

```bash
#!/bin/bash
# scripts/mig/teardown-mig.sh

echo "[!] Destroying all MIG compute instances..."
nvidia-smi mig -dci

echo "[!] Destroying all MIG GPU instances..."
nvidia-smi mig -dgi

echo "[!] Disabling MIG mode on all GPUs..."
nvidia-smi -mig 0

echo "[✓] MIG disabled. All GPUs back to full mode."
nvidia-smi
```
