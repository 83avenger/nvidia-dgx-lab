# configs/dpuflow/ovs-flow-templates.md
# BlueField-3 DPU — OVS Flow Rule Templates
# Apply on BF3 Arm OS (not host) after hw-offload is enabled

## Basic Terminology

| Term | Meaning |
|------|---------|
| `p0` | Physical port 0 (uplink to switch) |
| `pf0hpf` | Host PF representor (host-facing) |
| `pf0vf0` | VF0 representor (first container/VM) |
| `in_port` | Incoming interface |
| `output:` | Forwarding action |

---

## 1. Default Forwarding Rules (Baseline)

```bash
# Forward host traffic to uplink (and reverse)
ovs-ofctl add-flow br-offload "priority=100,in_port=pf0hpf,actions=output:p0"
ovs-ofctl add-flow br-offload "priority=100,in_port=p0,actions=output:pf0hpf"

# VF0 to uplink
ovs-ofctl add-flow br-offload "priority=100,in_port=pf0vf0,actions=output:p0"
ovs-ofctl add-flow br-offload "priority=100,in_port=p0,dl_dst=<VF0_MAC>,actions=output:pf0vf0"

# Verify offloaded
ovs-appctl dpctl/dump-flows type=offloaded
```

---

## 2. VLAN Segmentation

```bash
# Tag ingress from VF0 with VLAN 100
ovs-ofctl add-flow br-offload \
  "priority=200,in_port=pf0vf0,actions=push_vlan:0x8100,set_field:100->vlan_vid,output:p0"

# Strip VLAN 100 toward VF0
ovs-ofctl add-flow br-offload \
  "priority=200,in_port=p0,dl_vlan=100,actions=pop_vlan,output:pf0vf0"
```

---

## 3. RoCEv2 / RDMA QoS Marking (DSCP)

```bash
# Mark RoCEv2 egress traffic with DSCP 26 (lossless TC3)
ovs-ofctl add-flow br-offload \
  "priority=300,in_port=pf0hpf,ip,nw_proto=17,tp_dst=4791,\
   actions=set_field:26->ip_dscp,output:p0"
# Note: UDP 4791 = RoCEv2 port
```

---

## 4. IPsec Policy (DOCA-managed — reference only)

```bash
# IPsec SA is managed by DOCA ipsec app, not raw OVS flows.
# Trigger DOCA IPsec:
doca_ipsec_security_gw \
  --pf-name mlx5_0 \
  --mode transport \
  --src-ip 10.0.0.1 \
  --dst-ip 10.0.0.2 \
  --spi 0x1001 \
  --enc-key-type aes-gcm-256 \
  --enc-key <32-byte-hex-key>
```

---

## 5. Isolation: Block Host from Modifying Flows

When BF3 is in **DPU mode**, the host cannot modify OVS flows directly — all policy is enforced on the Arm OS. This is the zero-trust isolation model:

```
Host (DGX) → VF → [BF3 Arm OVS Policy Enforcement] → Physical Port → Switch
                          ↑
                 Host cannot see or modify these flows
```

---

## 6. Useful Verification Commands

```bash
# Show all OVS flows
ovs-ofctl dump-flows br-offload

# Show hardware-offloaded flows only
ovs-appctl dpctl/dump-flows type=offloaded

# Show OVS port stats
ovs-ofctl dump-ports br-offload

# Show OVS bridge info
ovs-vsctl show

# BF3 interface stats
ethtool -S p0 | grep -E "(rx|tx)_bytes"

# Check PF/VF representors
ls /sys/class/net/ | grep -E "pf|vf|p0"
```
