# 14 — Cluster Commissioning Checklist: DGX BasePOD

> **PSE Use**: Walk through this checklist with the customer during Day-0/Day-1 deployment.  
> Each section maps to runbooks, scripts, and playbooks in this repo.

---

## Phase 1: Physical Installation ✅

### Rack & Power
- [ ] Rack units reserved per DGX spec (10U per DGX H100)
- [ ] Dual PDUs per rack, 240V/32A circuits confirmed
- [ ] Power budget calculated: 10.2 kW per DGX H100 × node count + 20% headroom
- [ ] Cooling: CRAC/CRAH capacity ≥ cluster TDP (hot-aisle/cold-aisle or rear-door HX)
- [ ] UPS/generator: covers full cluster for ≥10 min clean shutdown

### Network Cabling
- [ ] InfiniBand NDR cables: length verified, QSFP112 transceivers confirmed
- [ ] Cable labeling: each cable tagged with source/destination port IDs
- [ ] Optical path testing: light levels within spec (−3 to −10 dBm)
- [ ] Out-of-band Ethernet cabling: all BMC ports connected to OOB switch
- [ ] Storage cables: 100GbE/IB to storage nodes

### Hardware Verification
- [ ] All DGX nodes power on and POST
- [ ] `nvidia-smi -L` shows 8 GPUs on every node
- [ ] IB HCA visible: `lspci | grep Mellanox`
- [ ] BF3 DPU detected: `lspci | grep BlueField`
- [ ] Serial numbers recorded for all DGX nodes → `nvidia-smi --query-gpu=serial --format=csv`

---

## Phase 2: OS & Driver Baseline ✅

### DGX OS
- [ ] DGX OS 6.x (Ubuntu 22.04-based) installed on all nodes
- [ ] All nodes at identical OS version: `cat /etc/dgx-release`
- [ ] NTP synchronized across all nodes: `chronyc tracking`
- [ ] DNS resolves all node hostnames
- [ ] Passwordless SSH between nodes (for MPI)

### NVIDIA Driver Stack
- [ ] Driver version identical across nodes: `nvidia-smi --query-gpu=driver_version --format=csv`
- [ ] CUDA toolkit installed: `nvcc --version`
- [ ] NCCL installed: `dpkg -l | grep libnccl`
- [ ] Fabric Manager active: `systemctl status nvidia-fabricmanager`
- [ ] NVSwitch health: `nvidia-smi nvlink --status -i 0`

### InfiniBand Stack
- [ ] Mellanox OFED / MLNX_OFED installed: `ofed_info -s`
- [ ] IB core modules loaded: `lsmod | grep ib_core`
- [ ] ConnectX-7 firmware at latest GA release: `mlxfwmanager --query`
- [ ] All IB ports Active: `ibstat | grep -c "State: Active"` = expected count

---

## Phase 3: Fabric Validation ✅

### InfiniBand
- [ ] OpenSM or UFM running on management node
- [ ] All compute nodes visible: `ibnetdiscover | grep -c "Ca"` = 8 (or cluster count)
- [ ] No port errors at baseline: `perfquery -x -a | grep -v "^0"`
- [ ] IB ping passes: `ibping -G <target_GUID> -c 100`
- [ ] RDMA write bandwidth: `ib_write_bw -d mlx5_0 --report_gbits` ≥ 380 Gb/s
- [ ] IB MTU set to 4096: `ibportstate <lid> <port> | grep MTU`

### GPU Direct RDMA
- [ ] nvidia-peermem loaded: `lsmod | grep nvidia_peermem`
- [ ] GPUDirect RDMA confirmed: `nvidia-smi topo -m` shows NV + PIX paths
- [ ] NCCL intra-node busbw ≥ 380 GB/s: `./scripts/nccl/run-nccl-tests.sh --nodes 1`
- [ ] NCCL inter-node busbw ≥ 320 GB/s (8 nodes): `./scripts/nccl/run-nccl-tests.sh --nodes 8`

---

## Phase 4: Platform Deployment ✅

### Kubernetes
- [ ] K8s cluster initialized (kubeadm / Rancher / OpenShift)
- [ ] All nodes in Ready state: `kubectl get nodes`
- [ ] CNI plugin deployed (Calico/Cilium/OVN-K8s)
- [ ] Cluster DNS resolving: `kubectl run test --image=busybox -- nslookup kubernetes`

### GPU Operator
- [ ] GPU Operator installed: `helm list -n gpu-operator`
- [ ] All GPU Operator pods Running: `kubectl get pods -n gpu-operator`
- [ ] nvidia-device-plugin functional: `kubectl describe node | grep nvidia.com/gpu`
- [ ] DCGM exporter metrics live: `curl http://<node>:9400/metrics | grep DCGM`
- [ ] MIG Manager deployed (if MIG enabled): `kubectl get ds -n gpu-operator | grep mig`

### Run:ai
- [ ] Run:ai Operator installed: `helm list -n runai`
- [ ] Cluster registered in Run:ai control plane: `runai cluster info`
- [ ] Projects and quotas created: `runai list projects`
- [ ] Test job submits and runs: `runai submit test --image nvcr.io/nvidia/cuda:12.3-base --gpu 1 -- nvidia-smi`

---

## Phase 5: Storage Integration ✅

- [ ] Storage fabric connected (100GbE or IB storage rail)
- [ ] WEKA/VAST client installed on all DGX nodes
- [ ] Filesystem mounted and accessible from all nodes: `df -h /mnt/weka`
- [ ] Write throughput ≥ target: `fio --rw=write --bs=1M --size=10G --numjobs=8`
- [ ] GDS active (if applicable): `gdscheck -p`
- [ ] K8s PVC provisioner working: `kubectl apply -f tests/storage-pvc-test.yaml`

---

## Phase 6: Monitoring & Alerting ✅

- [ ] Prometheus scraping all DGX nodes: `curl http://prometheus:9090/targets`
- [ ] Grafana accessible and DGX dashboards imported (ID: 12239, 1860)
- [ ] Alertmanager routing to Slack/email: send test alert
- [ ] XID alert fires correctly: `amtool alert add alertname=TestXID severity=critical`
- [ ] Temperature alert threshold set to 85°C in `monitoring/alerting/dgx-alerts.yml`

---

## Phase 7: Acceptance Tests ✅

```bash
# Run full acceptance test suite
./scripts/acceptance/full-acceptance-test.sh --cluster-size 8

# Individual tests:
./scripts/infiniband/ib-fabric-check.sh --detailed
./scripts/nccl/run-nccl-tests.sh --nodes 8
./scripts/gpu-burn/gpu-burn-stress.sh --duration 1800
./tests/rdma/rdma-bw-test.sh --server <mgmt-ip>
ansible-playbook playbooks/ib-fabric-validate.yml -i configs/air/inventory.ini
```

### Acceptance Criteria

| Test | Pass Threshold |
|------|----------------|
| IB port error rate | < 100 symbol errors / port |
| NCCL intra-node busbw | ≥ 380 GB/s (H100 NVLink) |
| NCCL inter-node busbw | ≥ 320 GB/s (NDR IB, 8 nodes) |
| GPU burn 30min | No XID errors, peak temp < 85°C |
| RDMA write BW | ≥ 350 Gb/s per link |
| Storage write | ≥ 20 GB/s per node |
| GPU utilization (burn) | ≥ 95% during load |
| Run:ai job scheduling | Test job starts within 60s |

---

## Phase 8: Handover ✅

- [ ] All acceptance test results documented and signed off
- [ ] Customer admins trained on: Run:ai, `nvidia-smi`, `runai` CLI, Grafana
- [ ] Runbooks delivered: `docs/13-day2-ops-runbook.md`
- [ ] NVIDIA Enterprise Support contract activated
- [ ] Node serial numbers registered in NGC/NPN portal
- [ ] Change management ticket closed
- [ ] As-built network diagram delivered
- [ ] Monitoring contact list updated (Slack channel, on-call rotation)

---

> ✅ **Sign-Off**: PSE Engineer: _______________ | Customer: _______________ | Date: ___________
