# 02 — InfiniBand Fabric Design: NDR / HDR for DGX Clusters

## IB Speed Tiers

| Generation | Speed | Use Case |
|-----------|-------|---------|
| EDR | 100 Gb/s | Legacy / A100 storage rail |
| HDR | 200 Gb/s | A100 compute rail |
| NDR | 400 Gb/s | H100/H200 compute rail |
| XDR | 800 Gb/s | Roadmap (2025+) |

---

## Fat-Tree Topology (DGX Cluster)

```
                        ┌─────────────────────────┐
                        │     Core Switches        │
                        │  QM9700 NDR (x2 spine)   │
                        └──────────┬──────────────┘
                                   │
               ┌───────────────────┼───────────────────┐
               │                   │                   │
        ┌──────┴──────┐    ┌───────┴──────┐    ┌──────┴──────┐
        │  Leaf SW-1  │    │  Leaf SW-2   │    │  Leaf SW-3  │
        │  QM9700 NDR │    │  QM9700 NDR  │    │  QM9700 NDR │
        └──────┬──────┘    └───────┬──────┘    └──────┬──────┘
               │                   │                   │
        ┌──────┴──────┐    ┌───────┴──────┐    ┌──────┴──────┐
        │  DGX H100   │    │  DGX H100    │    │  DGX H100   │
        │  8x CX-7    │    │  8x CX-7     │    │  8x CX-7    │
        └─────────────┘    └──────────────┘    └─────────────┘
```

---

## NVIDIA Quantum-2 QM9700 Key Facts

- 64-port NDR 400Gb/s
- Supports 800Gb/s NDR ports (2× NDR-400 bonded)
- Integrated subnet manager (UFM)
- SHARP (Scalable Hierarchical Aggregation and Reduction Protocol) for collective ops

---

## Subnet Manager: UFM vs OpenSM

### UFM (NVIDIA Unified Fabric Manager) — Recommended for DGX

```bash
# Install UFM on management server
apt install ufm-enterprise
systemctl enable --now ufmd

# Key UFM tasks
ufm-topology-viewer    # Visualize IB fabric
ufm-telemetry          # Port counters, error rates
```

### OpenSM (Open Source SM) — Lab / Small Clusters

```bash
# Install
apt install opensm

# Edit config
vi /etc/opensm/opensm.conf
# Set: guid_routing_order_file, fat_tree routing

# Start
systemctl enable --now opensm
```

---

## IB Routing Algorithms

| Algorithm | Use Case |
|-----------|---------|
| `fat_tree` | Default for DGX fat-tree topologies |
| `minhop` | Minimal-hop generic routing |
| `updn` | Up-Down for any tree |
| `dfsssp` | Deadlock-free for arbitrary topologies |

```bash
# Set routing in opensm.conf
routing_engine fat_tree
```

---

## RDMA Tuning (GPU-to-GPU)

```bash
# Set MTU to 4096 for RDMA
mlxconfig -d /dev/mst/mt4129_pciconf0 set DEFAULT_TCLASS=106 PF_TOTAL_SF=900

# Verify RDMA
ibv_devinfo -d mlx5_0
ibv_rc_pingpong -d mlx5_0    # latency test

# GPU Direct RDMA verify
nvidia-smi topo -m             # should show NVLink + IB together

# perfquery — check port counters
perfquery -x -G <GUID>
```

---

## IB Health Check Script

```bash
#!/bin/bash
# ib-fabric-check.sh

echo "=== IB Port States ==="
ibstat | grep -E "(CA|Port|State|Physical)"

echo "=== SM Active ==="
sminfo

echo "=== Fabric Topology ==="
ibnetdiscover | grep -c "Switch"

echo "=== Error Check ==="
perfquery -x | grep -E "(SymbolError|LinkError|RcvError)"

echo "=== RDMA Ping ==="
ibping -G $(ibstat | awk '/Port GUID/{print $3}' | head -1) -c 10
```

---

## Common IB Troubleshooting

| Issue | Command | Fix |
|-------|---------|-----|
| Port Down | `ibstat \| grep State` | Check cable, `mlxfwreset` |
| SM Not Active | `sminfo` | Restart opensm/UFM |
| High Symbol Errors | `perfquery -x` | Replace cable or SFP |
| RDMA Fails | `ibv_rc_pingpong` | Check GID, MTU match |
| Topology Mismatch | `ibnetdiscover` | UFM reroute |
