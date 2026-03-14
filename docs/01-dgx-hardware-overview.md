# 01 — DGX Hardware Overview: A100 / H100 / H200

## DGX A100

| Spec | Value |
|------|-------|
| GPUs | 8× NVIDIA A100 80GB SXM |
| GPU Memory | 640 GB HBM2e total |
| NVLink | NVLink 3rd Gen, 600 GB/s bidirectional per GPU |
| NVSwitch | 6× NVSwitch (full all-to-all 4.8 TB/s) |
| CPU | 2× AMD EPYC 7742 (128 cores total) |
| System RAM | 1 TB DDR4 |
| Storage | 30 TB NVMe |
| Networking | 8× ConnectX-6 (200Gb/s HDR IB or 200GbE) |
| TDP | 6.5 kW |

### MIG on A100
- Up to **7 MIG instances** per GPU
- Profiles: `1g.10gb`, `2g.20gb`, `3g.20gb`, `4g.40gb`, `7g.80gb`
- Isolation: dedicated SM partitions + HBM slices + L2 cache

---

## DGX H100

| Spec | Value |
|------|-------|
| GPUs | 8× NVIDIA H100 SXM5 80GB |
| GPU Memory | 640 GB HBM3 total |
| NVLink | NVLink 4th Gen, 900 GB/s bidirectional per GPU |
| NVSwitch | 4× NVSwitch (NVLink 4.0, 7.2 TB/s all-to-all) |
| CPU | 2× Intel Xeon Platinum 8480C (112 cores) |
| System RAM | 2 TB DDR5 |
| Storage | 30 TB NVMe (RAID-0) |
| Networking | 8× ConnectX-7 (400Gb/s NDR IB or 400GbE) |
| TDP | 10.2 kW |

### MIG on H100
- Up to **7 MIG instances** per GPU
- Same profile structure as A100 with expanded compute classes
- Multi-Instance GPU + Confidential Computing support

---

## DGX H200

| Spec | Value |
|------|-------|
| GPUs | 8× NVIDIA H200 SXM5 141GB |
| GPU Memory | 1.128 TB HBM3e total |
| Memory Bandwidth | 4.8 TB/s aggregate (600 GB/s per GPU) |
| NVLink | NVLink 4th Gen (same as H100) |
| Networking | 8× ConnectX-7 NDR400 |
| TDP | ~11 kW |

> H200 = H100 GPU die + 141GB HBM3e. Ideal for large LLM inference (70B+ parameters).

---

## GPU Comparison: PSE Quick Reference

| Feature | A100 SXM | H100 SXM5 | H200 SXM5 |
|---------|----------|-----------|-----------|
| Architecture | Ampere | Hopper | Hopper |
| HBM | 80GB HBM2e | 80GB HBM3 | 141GB HBM3e |
| HBM BW/GPU | 2 TB/s | 3.35 TB/s | 4.8 TB/s |
| FP8 Tensor | ❌ | ✅ | ✅ |
| MIG Slices | 7 | 7 | 7 |
| Transformer Engine | ❌ | ✅ | ✅ |
| NVLink Gen | 3 | 4 | 4 |
| IB NIC | ConnectX-6 | ConnectX-7 | ConnectX-7 |

---

## DGX BasePOD Reference Architecture

```
                    ┌────────────────────────────────────┐
                    │         NVIDIA DGX BasePOD          │
                    │                                    │
   ┌─────────┐      │  ┌──────┐ ┌──────┐ ┌──────┐       │
   │ Storage │◄─────┤  │ DGX  │ │ DGX  │ │ DGX  │  ...  │
   │ (VAST/  │      │  │ Node │ │ Node │ │ Node │       │
   │  WEKA)  │      │  └──┬───┘ └──┬───┘ └──┬───┘       │
   └─────────┘      │     │        │         │           │
                    │  ───┴────────┴─────────┴───────    │
                    │     InfiniBand NDR / Spectrum-X     │
                    │  ─────────────────────────────────  │
                    │     Out-of-Band Mgmt (BMC/iDRAC)   │
                    └────────────────────────────────────┘
```

### Key PSE Sizing Notes
- **Compute rail**: NDR400 IB (1:1 for GPU-to-GPU), HDR200 acceptable for A100
- **Storage rail**: Separate 100GbE or HDR IB for storage
- **Mgmt rail**: 1GbE OOB for BMC
- **Power**: Allow 15 kW/rack for H100 DGX + overhead
