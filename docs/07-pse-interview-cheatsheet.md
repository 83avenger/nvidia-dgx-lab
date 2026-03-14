# 07 — PSE Interview Cheat Sheet: NVIDIA DGX / Fabric / MIG / DPU

## PSE Core Competency Areas

### 1. DGX Hardware (Must Know Cold)

**Q: What's the difference between DGX A100 and H100?**
> H100 uses Hopper architecture with NVLink 4 (900 GB/s vs 600 GB/s), HBM3 (3.35 TB/s vs 2 TB/s), ConnectX-7 NDR400 vs ConnectX-6 HDR200, adds Transformer Engine and FP8 precision. H100 delivers ~3× LLM training throughput vs A100.

**Q: What is NVSwitch and why does it matter?**
> NVSwitch enables all-to-all GPU communication at full NVLink bandwidth. Without it, GPU-to-GPU transfers must traverse the PCIe bus (bottleneck). DGX H100 has 4× NVSwitch → 7.2 TB/s total bisection BW inside the node.

**Q: When would you recommend H200 over H100?**
> When the workload is **memory-capacity bound** — large LLM inference (70B, 405B parameter models). H200's 141GB HBM3e vs H100's 80GB allows serving larger models without tensor parallelism across nodes, reducing fabric dependency.

---

### 2. InfiniBand (Fabric Expert)

**Q: NDR vs HDR InfiniBand — when do you use each?**
> NDR (400Gb/s) is standard for H100/H200 DGX clusters — matches ConnectX-7 line rate. HDR (200Gb/s) is used for A100 clusters (ConnectX-6). Mixing generations requires speed matching at switch port level.

**Q: Explain SHARP and why it matters for AI training.**
> SHARP (Scalable Hierarchical Aggregation and Reduction Protocol) performs MPI collective operations (AllReduce) directly in the IB switch fabric, offloading CPU/GPU. Reduces AllReduce latency by ~50% at scale. Critical for distributed training (GPT, LLaMA).

**Q: How do you handle IB SM (Subnet Manager) HA?**
> Deploy primary OpenSM on dedicated management server, standby SM on second server. OpenSM supports master/standby election via `GUID` priority. UFM provides HA natively with active/standby cluster mode.

**Q: Customer reports intermittent RDMA failures. How do you diagnose?**
> 1. `perfquery -x` — check SymbolErrors, RcvErrors per port  
> 2. `ibstat` — verify all ports Active/Active  
> 3. `ibping` — verify connectivity  
> 4. Check MTU consistency: `ibportstate`  
> 5. Inspect SM logs: `cat /var/log/opensm.log`  
> 6. Check cable/SFP: `mlxlink -d mlx5_0 --rx_fec`

---

### 3. Spectrum-X (Ethernet AI Fabric)

**Q: When would you position Spectrum-X over IB to a customer?**
> 1. Customer has existing Ethernet operations team, no IB expertise  
> 2. Mixed workloads (AI + storage + web) on same fabric  
> 3. Multi-vendor interop requirements  
> 4. Government/regulated envs with standard network auditing tools  
> IB wins on latency and SHARP collectives. Spectrum-X wins on familiarity.

**Q: What is Adaptive Routing in Spectrum-X?**
> Per-packet load balancing across equal-cost paths based on real-time congestion signal. Traditional ECMP is per-flow (can cause elephant flow imbalance). AR reduces tail latency in AI training by 10–30%.

---

### 4. MIG Multi-Instance GPU

**Q: Customer wants to run 50 inference workloads on 8× H100 DGX. How?**
> Enable MIG, use `1g.10gb` profile → 7 instances per GPU × 8 GPUs = 56 MIG slices. Each slice runs independent inference (BERT, small GPT). Use Kubernetes + NVIDIA GPU Operator + MIG Manager to schedule.

**Q: What is CI vs GI in MIG?**
> GI (GPU Instance) is the hardware partition — isolated SM, L2, HBM. CI (Compute Instance) lives inside a GI and shares its HBM but divides SMs. A `3g.20gb` GI can hold one `3c.20gb` CI (all SMs) or potentially smaller CIs.

**Q: Can MIG instances communicate with NVLink?**
> Only `7g.80gb` (full GPU) retains NVLink. All sub-7g profiles break NVLink — inter-GPU communication goes over PCIe or IB. Design implication: large models needing NVSwitch cannot use MIG.

---

### 5. BlueField-3 DPU

**Q: Why install a DPU in a DGX cluster?**
> 1. **CPU offload**: OVS, IPsec, TLS processing moved to Arm cores → frees all 112 host CPU cores for GPU orchestration  
> 2. **Host isolation**: Host OS cannot modify its own network policy — zero-trust tenant isolation  
> 3. **Line-rate crypto**: 400Gb/s IPsec without CPU involvement  
> 4. **Storage offload**: NVMe-oF initiator acceleration

**Q: What is the difference between eNIC mode and DPU mode on BF3?**
> eNIC: Host controls NIC, BF3 is transparent smart NIC. DPU mode: BF3 Arm OS owns the NIC, host sees only a virtual function. DPU mode enables full host isolation and independent policy enforcement.

---

### 6. Sizing & Design (Pre-Sales PSE)

**Q: Customer wants to train a 70B LLaMA model. What DGX setup?**
> Minimum: 4× DGX H100 (32× H100 GPUs). 70B in BF16 = ~140GB. Tensor parallel across 2 GPUs per node (70GB per GPU), pipeline parallel across nodes. Recommend NDR IB fabric with SHARP for AllReduce. Storage: VAST Data or WEKA with NVMe-oF.

**Q: What fabric speed do you need for DGX H200?**
> H200 has ConnectX-7 NDR400 (same as H100). NDR400 IB or 400GbE (Spectrum-X). For >8 nodes, use NVIDIA Quantum-2 QM9700 NDR switches in fat-tree. At 64 nodes+, add spine layer.

---

## PSE Quick Reference Card

```
GPU MEMORY:     A100=80GB HBM2e | H100=80GB HBM3 | H200=141GB HBM3e
GPU BW/GPU:     A100=2TB/s      | H100=3.35TB/s  | H200=4.8TB/s
NVLINK GEN:     A100=NVL3       | H100=NVL4      | H200=NVL4
IB NIC:         A100=CX-6 HDR  | H100=CX-7 NDR  | H200=CX-7 NDR
MIG SLICES:     A100=7          | H100=7          | H200=7
TDP:            A100=400W       | H100=700W       | H200=700W
FABRIC:         A100=HDR200     | H100=NDR400     | H200=NDR400
SWITCH:         A100=QM8790     | H100=QM9700     | H200=QM9700
```
