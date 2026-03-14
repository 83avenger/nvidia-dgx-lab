# 03 — NVIDIA Spectrum-X: Ethernet AI Fabric

## What is Spectrum-X?

Spectrum-X is NVIDIA's **Ethernet-based AI fabric** combining:
- **Spectrum-4 switches** — 51.2 Tb/s, 800GbE capable
- **ConnectX-7 / BlueField-3 SmartNICs** — with NVIDIA Adaptive Routing
- **RoCEv2** — RDMA over Converged Ethernet v2

> Spectrum-X targets customers who want **lossless GPU-to-GPU RDMA over Ethernet** rather than InfiniBand, with similar performance for large AI training.

---

## Spectrum-X vs InfiniBand: PSE Decision Guide

| Factor | InfiniBand NDR | Spectrum-X Ethernet |
|--------|---------------|---------------------|
| Latency | ~600 ns | ~1.5 µs |
| Bandwidth (400G) | ✅ NDR400 | ✅ 400GbE |
| Congestion Control | IB CC | DCQCN + Adaptive Routing |
| Ecosystem | NVIDIA-only | Multi-vendor Ethernet |
| Management | UFM | NVUE / standard NOS |
| SHARP Collectives | ✅ | ❌ (roadmap) |
| Customer familiarity | Specialised | High (Ethernet) |
| Use for | Pure NVIDIA DGX | Hybrid DC + AI |

---

## Spectrum-4 Switch Key Specs

| Feature | Value |
|---------|-------|
| Model | SN5600 / SN5400 |
| Fabric BW | 51.2 Tb/s |
| Port options | 64× 800GbE, 128× 400GbE |
| Latency | < 300 ns cut-through |
| ASIC | Spectrum-4 |
| NOS | Cumulus Linux / NVIDIA NOS (NVUE) |

---

## RoCEv2 Configuration (Spectrum-4 + ConnectX-7)

### Switch Side — Lossless PFC + ECN

```bash
# NVUE — configure PFC lossless for RoCEv2 (DSCP 26)
nv set qos pfc 0 tx enable on rx enable on
nv set qos map dscp-tc 26 tc 3
nv set qos egress-scheduler tc 3 type strict
nv config apply
```

### Server Side — ConnectX-7 RoCEv2 Tuning

```bash
# Set RoCEv2 mode
cma_roce_mode -d mlx5_0 -p 1 -m 2    # 2 = RoCEv2

# Set DSCP for traffic class
cma_roce_tos -d mlx5_0 -p 1 -t 106   # DSCP 26 = TOS 104

# Enable ECN on NIC
mlxconfig -d /dev/mst/mt4129_pciconf0 set \
  ROCE_CC_PRIO_MASK_P1=255 \
  CLAMP_TGT_RATE_AFTER_TIME_INC_P1=1

# Verify
mlxlink -d mlx5_0 --pcie --rx_fec
```

---

## Adaptive Routing (Spectrum-X Feature)

NVIDIA Adaptive Routing dynamically selects the least-congested path per-packet:

```bash
# Enable AR on Spectrum-4 (NVUE)
nv set router adaptive-routing enable on
nv set interface swp1-64 router adaptive-routing enable on
nv config apply

# Verify AR stats
nv show interface swp1 router adaptive-routing counters
```

---

## DCQCN — Congestion Control for RoCEv2

DCQCN (Data Center Quantized Congestion Notification) flow:

```
Receiver detects congestion (ECN mark) →
  Sends CNP (Congestion Notification Packet) →
    Sender reduces injection rate (RTTCC algorithm) →
      Network clears → rate recovery
```

```bash
# Tune DCQCN parameters on CX-7
mlxconfig -d /dev/mst/mt4129_pciconf0 set \
  ROCE_CC_ALGORITHM_P1=1 \    # DCQCN
  INIT_ALPHA_P1=1023 \
  MIN_TIME_BETWEEN_CNPS_P1=4
```

---

## Spectrum-X Lab Topology (AIR Blueprint Reference)

```json
{
  "topology": {
    "switches": [
      { "name": "spectrum4-leaf-1", "model": "SN5600", "ports": 64 },
      { "name": "spectrum4-leaf-2", "model": "SN5600", "ports": 64 },
      { "name": "spectrum4-spine-1", "model": "SN5600", "ports": 64 }
    ],
    "servers": [
      { "name": "dgx-h100-01", "nic": "ConnectX-7", "speed": "400GbE" },
      { "name": "dgx-h100-02", "nic": "ConnectX-7", "speed": "400GbE" }
    ],
    "fabric_type": "spectrum-x",
    "rdma_protocol": "RoCEv2"
  }
}
```
