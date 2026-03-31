# 12 — AI Storage: WEKA & VAST Data for DGX Clusters

## Why Specialized Storage for AI?

Standard NFS/SAN cannot sustain GPU cluster I/O requirements:

| Scenario | Data Rate |
|----------|-----------|
| 8× H100 training (checkpointing) | 50–200 GB/s burst |
| Dataset streaming (ImageNet-scale) | 20–80 GB/s sustained |
| LLM checkpoint save (70B model, BF16) | ~140 GB in seconds |
| Multi-node AllReduce checkpoint sync | Must match IB fabric speed |

**Standard NAS/NFS**: 5–20 GB/s → bottleneck  
**WEKA / VAST Data**: 100–500+ GB/s → GPU-native  

---

## WEKA: Architecture

```
┌────────────────────────────────────────────────┐
│               DGX H100 Nodes                    │
│   WEKA client (kernel module + POSIX mount)     │
└──────────────────┬─────────────────────────────┘
                   │ InfiniBand NDR / 100GbE
┌──────────────────▼─────────────────────────────┐
│             WEKA Cluster (SSD Tier)             │
│  6–12 storage nodes × NVMe SSDs                │
│  All-active: every node serves I/O             │
│  POSIX, S3, NFS, SMB compatible                │
└────────────────────────────────────────────────┘
```

### WEKA Key Facts (PSE)

| Feature | Detail |
|---------|--------|
| Protocol | POSIX, NFS v4.2, S3, SMB |
| Media | NVMe SSD (all-flash) |
| Latency | ~200 µs (NVMe tier) |
| Throughput | Up to 500 GB/s aggregate |
| GPU Direct Storage | ✅ (GDS plugin) |
| Tiering | NVMe → S3/object store |
| Min cluster | 6 nodes |

### WEKA Mount on DGX

```bash
# Install WEKA client
curl https://get.weka.io | sh

# Mount WEKA filesystem
mount -t wekafs <weka-cluster-ip>/default /mnt/weka

# Enable GPU Direct Storage (GDS) for WEKA
modprobe nvidia-fs
weka local setup --drives 0 --cores 6

# Verify GDS active
cat /proc/driver/nvidia-fs/stats | grep gds
```

### WEKA + NCCL Checkpoint Config

```bash
# Set checkpoint directory to WEKA mount
export CHECKPOINT_DIR=/mnt/weka/checkpoints

# PyTorch DDP checkpoint save (multi-node)
# WEKA handles concurrent writes from all ranks without locking issues
torch.save(model.state_dict(), f"{CHECKPOINT_DIR}/epoch_{epoch}.pt")
```

---

## VAST Data: Architecture

```
┌──────────────────────────────────────────────────┐
│                 DGX H100 Nodes                    │
│      VAST client (NFS v3/v4, or S3)               │
└──────────────────┬───────────────────────────────┘
                   │ 100GbE / NDR IB
┌──────────────────▼───────────────────────────────┐
│         VAST Data Cluster (DASE Architecture)     │
│                                                   │
│  ┌──────────────────────────────────┐             │
│  │  CNodes (Compute Nodes)          │             │
│  │  Stateless, NFS/S3 protocol      │             │
│  └──────────────────────────────────┘             │
│  ┌──────────────────────────────────┐             │
│  │  DNodes (Storage Nodes)          │             │
│  │  NVMe SSDs + 3DXPoint            │             │
│  └──────────────────────────────────┘             │
└──────────────────────────────────────────────────┘
```

### VAST Key Facts (PSE)

| Feature | Detail |
|---------|--------|
| Protocol | NFS v3/v4, S3, SMB |
| Architecture | DASE (Disaggregated, Shared Everything) |
| Latency | ~500 µs (NFS) |
| Throughput | 1 TB/s+ at scale |
| GPU Direct Storage | ✅ |
| Global namespace | Single FS across sites |
| Data reduction | Inline dedupe + compression |
| Min cluster | 4 nodes (2C + 2D) |

### VAST Mount on DGX

```bash
# NFS v4 mount (simple, no client agent)
mount -t nfs4 -o nfsvers=4,proto=rdma,port=20049 \
  <vast-vip>:/datasets /mnt/vast/datasets

# Verify RDMA mount (improves throughput over TCP NFS)
mount | grep vast
nfsstat -m | grep rdma

# For GPU Direct Storage with VAST
# Use VAST's GDS-enabled NFS or VAST S3 + cuFile API
```

---

## Storage Comparison: PSE Decision Table

| Factor | WEKA | VAST Data | Standard NFS |
|--------|------|-----------|-------------|
| Throughput | 500 GB/s | 1 TB/s+ | 5–20 GB/s |
| Latency | ~200 µs | ~500 µs | 1–5 ms |
| GPU Direct Storage | ✅ kernel | ✅ | ❌ |
| Protocol | POSIX/NFS/S3 | NFS/S3/SMB | NFS/SMB |
| Client required | ✅ kernel module | ❌ (standard NFS) | ❌ |
| Tiering | NVMe → S3 | NVMe → 3DXPoint → S3 | Manual |
| Best for | HPC + AI training | Large-scale AI + multi-site | Dev/test only |
| UAE deployments | G42/Core42/Khazna | Available via VAST UAE | Any |

---

## GPU Direct Storage (GDS) — PSE Concept

GDS allows the GPU to read/write storage **directly** — bypassing the CPU and system RAM:

```
WITHOUT GDS:
  NVMe → CPU DRAM → GPU HBM    (double copy, CPU bottleneck)

WITH GDS:
  NVMe → GPU HBM directly       (zero-copy, PCIe/IB DMA)
```

```bash
# Verify GDS support
nvidia-smi | grep "CUDA Version"    # needs 11.4+
modprobe nvidia-fs

# Test GDS throughput
gdscheck -p                         # WEKA/VAST GDS check
cufile_sample /mnt/weka/testfile    # cuFile API test
```

---

## Storage Sizing Guide for DGX BasePOD

| Cluster Size | Recommended Storage | Capacity Target |
|-------------|--------------------|-----------------| 
| 1–4 DGX nodes | WEKA 6-node or VAST 4-node | 500 TB NVMe |
| 8–16 DGX nodes | WEKA 12-node or VAST 8-node | 1–2 PB NVMe |
| 32+ DGX nodes (SuperPOD) | VAST Enterprise or WEKA cluster + S3 tier | 5–10 PB+ |

**Rule of thumb**: storage fabric bandwidth ≥ 25% of total IB fabric bandwidth  
→ 8× DGX H100 = 8 × 400Gb/s = 3.2 Tb/s IB → need ≥ 800 Gb/s storage throughput
