# 13 — Day-2 Operations Runbook: DGX Cluster

## Overview

This runbook covers recurring operational tasks for DGX cluster administrators and PSEs after initial deployment. Organized by frequency.

---

## Daily Checks

### 1. GPU Health Sweep

```bash
#!/bin/bash
# Quick daily GPU health check — run on each DGX node or via Ansible

echo "=== $(hostname) — $(date) ==="

# GPU summary
nvidia-smi --query-gpu=index,name,temperature.gpu,power.draw,memory.used,utilization.gpu,ecc.errors.uncorrected.volatile.total \
  --format=csv,noheader

# XID errors since last boot
nvidia-smi | grep -i "xid\|error" | grep -v "^$" || echo "No XID errors"

# Fabric Manager status (NVSwitch health)
systemctl is-active nvidia-fabricmanager && echo "FabricManager: OK" || echo "FabricManager: FAILED"
```

### 2. IB Fabric Quick Check

```bash
# Check SM active and node count
sminfo && ibnetdiscover | grep -c "Ca" | xargs echo "Active compute nodes:"

# Error sweep — run on subnet manager node
perfquery -x -a 2>/dev/null | grep -E "SymbolErrors|RcvErrors" | \
  awk -F: '{sum+=$2} END{print "Total port errors:", sum}'
```

### 3. Run:ai Cluster Status

```bash
runai cluster info
runai list jobs -A | grep -E "Failed|Error" || echo "No failed jobs"
runai top job | head -20
```

### 4. Monitoring Alerts Review

```bash
# Check Prometheus active alerts
curl -s http://prometheus:9090/api/v1/alerts | \
  python3 -c "import json,sys; d=json.load(sys.stdin); \
  [print(a['labels']['alertname'], a['labels'].get('instance','')) \
   for a in d['data']['alerts'] if a['state']=='firing']"
```

---

## Weekly Tasks

### 5. DCGM Full Health Check

```bash
# Run DCGM diagnostic (level 3 = comprehensive)
dcgmi diag -r 3

# Check for throttling reasons
nvidia-smi --query-gpu=index,clocks_throttle_reasons.active \
  --format=csv,noheader

# Review ECC error history
nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total \
  --format=csv,noheader
```

### 6. IB Cable & Transceiver Check

```bash
#!/bin/bash
# Check all ConnectX-7 ports for signal quality
for DEV in /dev/mst/mt4129_pciconf*; do
  echo "=== $DEV ==="
  mlxlink -d "$DEV" --rx_fec --port 1 2>/dev/null | \
    grep -E "(FEC|BER|Speed|State|Active)"
done
```

### 7. GPU Driver & Firmware Review

```bash
# Current driver version
nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1

# GPU firmware version
nvidia-smi --query-gpu=vbios_version --format=csv,noheader

# ConnectX-7 firmware
mlxfwmanager --query 2>/dev/null | grep -E "FW Version|Device"

# Compare to latest:
# NVIDIA Driver: https://www.nvidia.com/en-us/datacenter/
# ConnectX-7: https://network.nvidia.com/support/firmware/
```

### 8. Storage Health (WEKA/VAST)

```bash
# WEKA
weka status                  # cluster health
weka fs                      # filesystem usage
weka alerts                  # active alerts

# VAST
vastcli cluster list         # cluster status
vastcli vippool list         # VIP pool health
vastcli quota list           # quota usage
```

---

## Monthly Tasks

### 9. NCCL Baseline Re-test

```bash
# Re-run NCCL tests and compare to baseline
./scripts/nccl/run-nccl-tests.sh --nodes 8 --test all_reduce 2>&1 | \
  tee /var/log/nccl-monthly-$(date +%Y%m).log

# Compare vs last month
diff /var/log/nccl-monthly-$(date -d "last month" +%Y%m).log \
     /var/log/nccl-monthly-$(date +%Y%m).log
```

### 10. GPU Burn Acceptance Re-test

```bash
# Re-run thermal test after any hardware changes
./scripts/gpu-burn/gpu-burn-stress.sh --duration 1800  # 30 min
```

### 11. Certificate & Token Rotation

```bash
# Rotate Run:ai service account tokens
kubectl -n runai rollout restart deployment/runai-scheduler

# Renew kubeconfig certificates if expiring
kubeadm certs check-expiration
kubeadm certs renew all
```

### 12. Capacity Report

```bash
#!/bin/bash
# Generate monthly GPU utilization report from Prometheus

PROM_URL="http://prometheus:9090"
END=$(date +%s)
START=$((END - 30*86400))    # 30 days

echo "=== Monthly GPU Utilization Report — $(date +%Y-%m) ==="

# Avg utilization per node
curl -s "${PROM_URL}/api/v1/query_range" \
  --data-urlencode "query=avg_over_time(DCGM_FI_DEV_GPU_UTIL[30d])" \
  --data-urlencode "start=${START}" \
  --data-urlencode "end=${END}" \
  --data-urlencode "step=3600" | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['data']['result']:
  avg = sum(float(v[1]) for v in r['values']) / len(r['values'])
  print(f\"  {r['metric'].get('instance','?')}: {avg:.1f}% avg utilization\")
"
```

---

## Incident Response Procedures

### P1: GPU XID Error (Critical)

```bash
# 1. Identify affected GPU
nvidia-smi dmon -s pct | grep -v "^#"   # live monitoring
dmesg | grep -i "xid"                    # kernel XID log

# 2. Common XID codes
# XID 8  = GPU memory error — check ECC, run gpu-burn
# XID 43 = GPU soft reset  — restart process
# XID 48 = Double-bit ECC  — hardware replacement needed
# XID 79 = GPU diagnostic  — run dcgmi diag

# 3. Isolate node from Run:ai scheduler
kubectl cordon dgx-h100-01

# 4. Run full DCGM diagnostic
dcgmi diag -g $(dcgmi group -l | grep "All GPUs" | awk '{print $3}') -r 3

# 5. If hardware fault: raise case with NVIDIA Enterprise Support
# nvidia-smi --help-query-gpu | grep serial
nvidia-smi --query-gpu=serial --format=csv,noheader
```

### P2: IB Port Down

```bash
# 1. Identify down port
ibstat | grep -B5 "State: Down"

# 2. Check physical layer
mlxlink -d mlx5_0 --port 1 | grep -E "State|Speed|FEC"

# 3. Try reset
mlxfwreset -d mlx5_0 -y reset   # WARNING: disrupts traffic

# 4. If cable issue — check with mlxlink BER
mlxlink -d mlx5_0 --rx_fec | grep BER
# BER > 1e-12 = replace cable/transceiver

# 5. Force SM re-route around failed port
# On UFM: Fabric → Ports → Disable port → Re-route
# On OpenSM: will auto-reroute after sweep_interval
```

### P3: Run:ai Scheduler Failure

```bash
# 1. Check scheduler pod
kubectl get pods -n runai | grep scheduler
kubectl logs -n runai deployment/runai-scheduler --tail=100

# 2. Restart scheduler
kubectl -n runai rollout restart deployment/runai-scheduler

# 3. Check jobs re-queued
runai list jobs -A | grep Pending

# 4. If persistent — check K8s API connectivity
kubectl cluster-info
kubectl get nodes
```

### P4: Node Failure / Reboot

```bash
# 1. Drain node gracefully (moves Run:ai workloads)
kubectl drain dgx-h100-03 --ignore-daemonsets --delete-emptydir-data

# 2. After node comes back
kubectl uncordon dgx-h100-03

# 3. Verify GPU Operator re-initialized
kubectl get pods -n gpu-operator -o wide | grep dgx-h100-03

# 4. Re-run fabric check
ansible-playbook playbooks/ib-fabric-validate.yml \
  -i configs/air/inventory.ini --limit dgx-h100-03

# 5. Verify MIG config restored (if applicable)
ansible-playbook playbooks/configure-mig.yml \
  -i configs/air/inventory.ini --limit dgx-h100-03
```

---

## Useful One-Liners

```bash
# All GPU temps across cluster
ansible dgx_nodes -i configs/air/inventory.ini -a \
  "nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader"

# All IB port states across cluster
ansible dgx_nodes -i configs/air/inventory.ini -a "ibstat | grep State"

# GPU utilization heatmap (current)
nvidia-smi --query-gpu=index,utilization.gpu --format=csv,noheader | \
  awk -F, '{printf "GPU%s: %s%%\n", $1, $2}'

# Find idle GPUs (util < 5%)
nvidia-smi --query-gpu=index,utilization.gpu --format=csv,noheader | \
  awk -F'[, %]' '$2+0 < 5 {print "IDLE: GPU"$1}'

# Which jobs are using which GPUs
runai list jobs -A -o json 2>/dev/null | \
  python3 -c "import json,sys; \
  [print(j['name'], j.get('allocatedGPU','?'), 'GPUs') \
   for j in json.load(sys.stdin)]" || true

# Storage usage check
df -h /mnt/weka /mnt/vast 2>/dev/null || df -h /mnt/nfs
```
