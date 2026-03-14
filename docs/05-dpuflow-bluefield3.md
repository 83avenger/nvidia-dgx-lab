# 05 — BlueField-3 DPU: Offload, Isolation & DOCA

## What is BlueField-3?

BlueField-3 (BF3) is NVIDIA's **3rd-generation DPU** — a complete Arm-based system-on-chip embedded in a PCIe card with:
- 16× Arm A78 cores (Cortex)
- ConnectX-7 400Gb/s NIC embedded
- Hardware accelerators: crypto, regex, compression
- Dedicated DDR5 (up to 32 GB)
- OVS offload, IPsec offload, TLS offload

---

## BF3 DPU Architecture

```
┌────────────────────────────────────────────────────┐
│                 BlueField-3 DPU                    │
│                                                    │
│  ┌─────────────────────────┐  ┌─────────────────┐  │
│  │   Arm Subsystem          │  │  ConnectX-7 NIC │  │
│  │  16× Cortex-A78 cores   │  │  2× 200GbE or   │  │
│  │  32 GB DDR5             │  │  1× 400GbE NDR  │  │
│  │  DOCA SDK runtime       │  └────────┬────────┘  │
│  └─────────────┬───────────┘           │           │
│                │                  ┌────┴────┐      │
│                │                  │ HW Accel│      │
│                │                  │ Crypto  │      │
│                │                  │ RegEx   │      │
│                │                  │ Compress│      │
│                │                  └─────────┘      │
│                └──────────────────────────────────┐ │
│                         PCIe to Host              │ │
└───────────────────────────────────────────────────┘
         │
    ┌────┴──────────────────────────┐
    │          Host Server          │
    │    (DGX H100 / x86 CPU)      │
    └───────────────────────────────┘
```

---

## BF3 Operating Modes

| Mode | Description | Use Case |
|------|-------------|---------|
| **Embedded NIC (eNIC)** | BF3 acts as smart NIC, host controls network | Default / Legacy |
| **Separated Host** | BF3 Arm OS runs independently from host | Zero-trust, tenant isolation |
| **DPU Mode** | Full DPU — Arm owns NIC, host sees virtual NIC | Cloud, NFV, AI isolation |

```bash
# Check current mode
cat /sys/bus/pci/devices/<BDF>/bf_mode

# Switch to DPU mode (requires BFB flash)
bfb-install --rshim /dev/rshim0 --image bf3-dpu-mode.bfb
```

---

## OVS Hardware Offload (BF3)

```bash
# On BF3 Arm OS: Enable hardware offload OVS
ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
systemctl restart openvswitch

# Add uplink & representors
ovs-vsctl add-br br-offload
ovs-vsctl add-port br-offload p0        # physical port
ovs-vsctl add-port br-offload pf0hpf    # host PF representor
ovs-vsctl add-port br-offload pf0vf0    # VF0 representor

# Verify offload
ovs-appctl dpctl/dump-flows type=offloaded
```

---

## IPsec Offload (DOCA Flow)

```bash
# Configure IPsec SA on BF3
doca_ipsec_security_gw \
  --sa-dir inbound \
  --src-ip 10.0.0.1 \
  --dst-ip 10.0.0.2 \
  --spi 0x1001 \
  --enc-key-type aes-gcm-256

# Verify crypto acceleration
mlxlink -d mlx5_0 -m | grep -i ipsec
```

---

## Host Isolation with DPU

DPU provides **zero-trust host isolation** — the host cannot modify its own network policy:

```
Host (DGX)                      BF3 DPU Arm
─────────────────               ─────────────────────────────
VMs / Containers ──VF────────►  OVS (HW Offload)
                               ACL / Security Policy
                               ──────────────────────
                               Physical Network ──────► Spine
```

---

## DOCA SDK Applications (Reference)

| App | Purpose |
|-----|---------|
| `doca_flow` | Pipeline-based packet processing |
| `doca_ipsec` | Hardware IPsec offload |
| `doca_rdma` | RDMA operations via DPU |
| `doca_regex` | L7 DPI regex acceleration |
| `doca_compress` | Hardware LZ4/deflate |
| `doca_sha` | Crypto hash acceleration |

```bash
# Install DOCA SDK
apt install doca-sdk doca-runtime

# Run DOCA flow example
/opt/mellanox/doca/samples/doca_flow/flow_drop/flow_drop \
  -a 03:00.0,representor=[0] -a 03:00.1,representor=[0]
```

---

## BF3 DPU Health Check Script

```bash
#!/bin/bash
# scripts/dpuflow/dpu-health-check.sh

echo "=== BF3 DPU Status ==="
cat /sys/class/net/*/operstate 2>/dev/null || echo "Check rshim"

echo "=== rshim Connection ==="
ls -la /dev/rshim*

echo "=== OVS Offload Status ==="
ovs-vsctl get Open_vSwitch . other_config:hw-offload

echo "=== Offloaded Flows ==="
ovs-appctl dpctl/dump-flows type=offloaded | wc -l

echo "=== BF3 FW Version ==="
flint -d /dev/mst/mt41692_pciconf0 q | grep FW

echo "=== DOCA Runtime ==="
dpkg -l | grep doca
```

---

## PSE Key Talking Points: BF3 DPU

1. **Performance**: OVS offload moves 100% of packet processing off host CPUs → more CPU for GPU workloads
2. **Security**: Host isolation — compromised host cannot alter network policy
3. **Scalability**: IPsec/TLS at line rate without CPU overhead
4. **Kubernetes CNI**: Works with OVN-Kubernetes, Antrea for pod-level network policy in GPU clusters
