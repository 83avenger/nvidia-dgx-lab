# 09 — NCCL Tests: GPU-to-GPU Bandwidth & Collective Validation

## What is NCCL?

NVIDIA Collective Communications Library (NCCL) is the communication backend for **all distributed GPU training** (PyTorch DDP, Horovod, JAX, etc.). It handles:
- `AllReduce` — aggregate gradients across GPUs/nodes
- `AllGather`, `ReduceScatter` — tensor parallelism primitives
- `Broadcast`, `Scatter` — data distribution

**NCCL performance = training throughput.** Low NCCL bandwidth = bottlenecked training regardless of GPU compute power.

---

## NCCL Transport Priority (DGX H100)

```
GPU 0 ↔ GPU 1 (same node, NVLink)   → NVLink 4.0 (900 GB/s bidirectional)
GPU 0 ↔ GPU 8 (node 0 → node 1)     → InfiniBand NDR (400 Gb/s)
GPU 0 ↔ GPU 8 (no IB, RoCEv2)       → Spectrum-X 400GbE RoCEv2
```

NCCL auto-selects: NVLink > IB/RDMA > TCP

---

## nccl-tests: Installation & Build

```bash
# Clone nccl-tests
git clone https://github.com/NVIDIA/nccl-tests.git
cd nccl-tests

# Build (requires CUDA toolkit + NCCL installed)
make MPI=1 MPI_HOME=/usr/local/mpi \
     CUDA_HOME=/usr/local/cuda \
     NCCL_HOME=/usr/local/nccl

# Binary location
ls build/
# all_reduce_perf, all_gather_perf, reduce_scatter_perf, broadcast_perf ...
```

---

## Test 1: Intra-Node AllReduce (NVLink)

Tests all 8 GPUs within a single DGX node — validates NVLink fabric:

```bash
# Single-node, all 8 GPUs
./build/all_reduce_perf \
  -b 8 -e 8G -f 2 \
  -g 8 \
  -n 100

# Expected output columns:
# size(B) | count | type | redop | root | time(us) | algbw(GB/s) | busbw(GB/s) | error
#
# Target busbw for H100 NVLink: ~400 GB/s at 8G message
```

---

## Test 2: Inter-Node AllReduce (InfiniBand)

Tests across 4 DGX nodes (32 GPUs total) — validates IB fabric:

```bash
# 4-node MPI AllReduce
mpirun \
  --hostfile /etc/mpi/hostfile \
  -np 32 \
  --map-by ppr:8:node \
  --bind-to numa \
  -x NCCL_DEBUG=INFO \
  -x NCCL_IB_DISABLE=0 \
  -x NCCL_NET_GDR_LEVEL=5 \
  -x NCCL_IB_GID_INDEX=3 \
  ./build/all_reduce_perf \
    -b 1G -e 8G -f 2 \
    -g 1 \
    -n 20

# Target busbw for H100 NDR IB: ~350-380 GB/s at 4G+ message size
```

---

## Test 3: AllReduce on Spectrum-X (RoCEv2)

```bash
mpirun \
  --hostfile /etc/mpi/hostfile \
  -np 32 \
  --map-by ppr:8:node \
  -x NCCL_DEBUG=WARN \
  -x NCCL_IB_DISABLE=1 \
  -x NCCL_SOCKET_IFNAME=^lo,docker \
  -x NCCL_NET_GDR_LEVEL=5 \
  -x NCCL_ALGO=Ring \
  ./build/all_reduce_perf \
    -b 1G -e 8G -f 2 \
    -g 1 -n 20

# RoCEv2 target: 80-90% of IB NDR performance at scale
```

---

## NCCL Environment Variables: PSE Reference

| Variable | Value | Purpose |
|----------|-------|---------|
| `NCCL_DEBUG` | `INFO` / `WARN` | Verbosity (INFO for troubleshooting) |
| `NCCL_IB_DISABLE` | `0` / `1` | Force disable/enable IB transport |
| `NCCL_NET_GDR_LEVEL` | `5` | GPU Direct RDMA — `5` = enable always |
| `NCCL_IB_GID_INDEX` | `3` | RoCEv2 GID index on ConnectX-7 |
| `NCCL_SOCKET_IFNAME` | `^lo` | Exclude loopback from TCP fallback |
| `NCCL_P2P_LEVEL` | `NVL` | Force NVLink for intra-node P2P |
| `NCCL_ALGO` | `Ring`/`Tree` | Collective algorithm selection |
| `NCCL_TOPO_FILE` | `/path/topo.xml` | Custom topology override |
| `NCCL_IB_HCA` | `mlx5_0:1` | Pin NCCL to specific HCA port |

---

## Bandwidth Reference Table (PSE)

| Scenario | Transport | Expected busbw |
|----------|-----------|----------------|
| 2× H100 intra-node | NVLink 4 | ~450 GB/s |
| 8× H100 intra-node AllReduce | NVLink 4 + NVSwitch | ~400 GB/s |
| 2-node 16× H100 AllReduce | NDR IB | ~380 GB/s |
| 8-node 64× H100 AllReduce | NDR IB + SHARP | ~340 GB/s |
| 8-node RoCEv2 AllReduce | Spectrum-X | ~300 GB/s |

---

## Kubernetes NCCL Test Job

```yaml
# tests/nccl/nccl-allreduce-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: nccl-allreduce-test
  namespace: default
spec:
  template:
    spec:
      restartPolicy: Never
      hostNetwork: true
      hostIPC: true
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
      containers:
        - name: nccl-test
          image: nvcr.io/nvidia/pytorch:24.01-py3
          command:
            - /bin/bash
            - -c
            - |
              cd /opt/nccl-tests && \
              make MPI=1 CUDA_HOME=/usr/local/cuda && \
              ./build/all_reduce_perf -b 1G -e 8G -f 2 -g 8 -n 20
          resources:
            limits:
              nvidia.com/gpu: 8
          env:
            - name: NCCL_DEBUG
              value: "WARN"
            - name: NCCL_IB_DISABLE
              value: "0"
            - name: NCCL_NET_GDR_LEVEL
              value: "5"
          securityContext:
            capabilities:
              add: ["IPC_LOCK"]
          volumeMounts:
            - name: shm
              mountPath: /dev/shm
      volumes:
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 64Gi
```

---

## Troubleshooting Low NCCL Performance

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| busbw < 50% expected | IB not used, falling back to TCP | Set `NCCL_IB_DISABLE=0`, check `NCCL_DEBUG=INFO` |
| GDR not active | GPU Direct RDMA disabled | Set `NCCL_NET_GDR_LEVEL=5`, check `nvidia-peermem` module |
| Timeout on multi-node | SM firewall blocking IB | Open UDP 4791 (RoCEv2) or IB ports |
| High variance | IB fabric congestion | Check `perfquery` error counters, UFM |
| NVLink not used intra-node | Wrong `NCCL_P2P_LEVEL` | Set `NCCL_P2P_LEVEL=NVL` |
