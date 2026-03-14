# 🖥️ NVIDIA DGX / A100 / H100 / H200 Cluster Lab
> **PSE Reference Lab** — Fabric, MIG, DPU, NVIDIA AIR simulation, and cluster deployment guides  
> Built by: [Ayub | 83avenger](https://83avenger.github.io) · CISSP · PCNSE · AZ-104

---

## 📐 Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                   NVIDIA DGX Cluster (8-Node)               │
│                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ DGX H100 │  │ DGX H100 │  │ DGX H200 │  │ DGX A100 │   │
│  │ 8x H100  │  │ 8x H100  │  │ 8x H200  │  │ 8x A100  │   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘   │
│       │              │              │              │         │
│  ─────┴──────────────┴──────────────┴──────────────┴─────   │
│           InfiniBand NDR (400Gb/s) / Spectrum-X             │
│  ─────────────────────────────────────────────────────────  │
│           ConnectX-7 / BlueField-3 DPU per node             │
└─────────────────────────────────────────────────────────────┘
```

---

## 📂 Repo Structure

```
nvidia-dgx-lab/
├── docs/
│   ├── 01-dgx-hardware-overview.md       # DGX A100 / H100 / H200 specs & positioning
│   ├── 02-infiniband-fabric-design.md    # NDR IB topology, zoning, RDMA tuning
│   ├── 03-spectrum-x-ethernet.md        # Spectrum-X RoCEv2 for AI fabric
│   ├── 04-mig-profiles-guide.md         # MIG partitioning for A100/H100
│   ├── 05-dpuflow-bluefield3.md         # BlueField-3 DPU offload & isolation
│   ├── 06-nvidia-air-lab.md             # NVIDIA AIR simulation walkthrough
│   └── 07-pse-interview-cheatsheet.md   # PSE-level Q&A for cluster interviews
├── configs/
│   ├── ib/                              # InfiniBand switch configs (UFM/OpenSM)
│   ├── mig/                             # MIG partition YAML profiles
│   ├── spectrum-x/                      # Spectrum-X switch config templates
│   ├── air/                             # NVIDIA AIR topology JSON blueprints
│   └── dpuflow/                         # DPU OVS/flow rule templates
├── scripts/
│   ├── infiniband/                      # IB fabric validation & ibstat scripts
│   ├── mig/                             # MIG setup & teardown automation
│   ├── spectrum-x/                      # Spectrum-X health check scripts
│   └── dpuflow/                         # BlueField DPU provisioning scripts
├── playbooks/
│   ├── deploy-dgx-cluster.yml           # Ansible: full cluster bootstrap
│   ├── configure-mig.yml                # Ansible: MIG profile push
│   ├── ib-fabric-validate.yml           # Ansible: IB health checks
│   └── dpu-offload-enable.yml           # Ansible: DPU offload activation
└── .github/workflows/
    └── lab-validate.yml                  # CI: dry-run lint & validation
```

---

## 🚀 Quick Start

### 1 — Clone & Set Up

```bash
git clone https://github.com/83avenger/nvidia-dgx-lab.git
cd nvidia-dgx-lab
pip install ansible netmiko paramiko
```

### 2 — Simulate in NVIDIA AIR

```bash
# Import the AIR topology blueprint
cd configs/air/
# Upload dgx-8node-air-topology.json to air.ngc.nvidia.com
```

### 3 — Deploy MIG Profiles (A100/H100)

```bash
cd scripts/mig/
chmod +x setup-mig.sh
sudo ./setup-mig.sh --profile 3g.20gb --gpu-ids 0,1,2,3
```

### 4 — Validate InfiniBand Fabric

```bash
cd scripts/infiniband/
./ib-fabric-check.sh    # Runs ibstat, ibping, perfquery
```

---

## 🧩 Topics Covered

| Area | Details |
|------|---------|
| **GPU Hardware** | DGX A100 (8x A100 80GB), H100 SXM5, H200 SXM5 — TDP, NVLink, NVLS |
| **MIG** | 7 slices A100 / H100; profiles: 1g.10gb → 7g.80gb; CI/GI concepts |
| **InfiniBand** | NDR 400Gb/s, HDR 200Gb/s; UFM, OpenSM, subnet manager failover |
| **Spectrum-X** | RoCEv2 lossless Ethernet AI fabric; Adaptive Routing, DCQCN |
| **BlueField-3 DPU** | OVS offload, IPSec, Arm cores, host isolation, DOCA SDK |
| **NVIDIA AIR** | Free cloud simulation; topology JSON; DGX blueprint import |
| **Ansible** | Idempotent playbooks for full cluster lifecycle |

---

## 🎯 PSE Use Cases

This lab is designed for **NVIDIA Professional Service Engineers** validating:

- Pre-sales PoC environments for AI/HPC clusters
- Customer onboarding for DGX BasePOD deployments  
- Fabric troubleshooting (IB vs Ethernet trade-offs)
- MIG multi-tenancy demonstrations
- DPU network offload performance benchmarking

---

## 🔗 References

- [NVIDIA DGX H100 System Architecture](https://www.nvidia.com/en-us/data-center/dgx-h100/)
- [NVIDIA UFM Documentation](https://docs.nvidia.com/networking/display/UFMEnterpriseUMv6161)
- [MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/)
- [BlueField-3 DPU Documentation](https://docs.nvidia.com/networking/display/BlueField3DPU)
- [NVIDIA AIR](https://air.ngc.nvidia.com)
- [Spectrum-X Architecture](https://www.nvidia.com/en-us/networking/spectrumx/)

---

> ⚡ *Part of the [83avenger PSE Portfolio](https://83avenger.github.io) — Infrastructure · Cybersecurity · AI/HPC*
