# 06 — NVIDIA AIR: Free Lab Simulation for DGX Clusters

## What is NVIDIA AIR?

**NVIDIA Air** (air.ngc.nvidia.com) is a **cloud-hosted network simulation platform** that lets you build virtual topologies including:
- Cumulus Linux switches (Spectrum/Spectrum-4 simulation)
- Ubuntu servers (simulating DGX compute nodes)
- InfiniBand fabric simulation (partial)
- Pre-built NVIDIA reference blueprints

> Free tier available — ideal for PSE demo prep, customer PoC walkthroughs, and cert study.

---

## Access NVIDIA AIR

```
URL: https://air.ngc.nvidia.com
Auth: NGC account (free at ngc.nvidia.com)
```

---

## AIR Topology Blueprint: 8-Node DGX Cluster

```json
{
  "air_topology": {
    "version": "2.0",
    "name": "DGX-H100-8Node-Cluster",
    "description": "8x DGX H100 nodes with InfiniBand leaf-spine fabric",
    "nodes": [
      {
        "name": "dgx-h100-01",
        "os": "ubuntu-22.04",
        "cpu": 8,
        "memory": 16384,
        "interfaces": [
          { "name": "eth0", "mac": "auto", "ip": "192.168.100.11/24" },
          { "name": "ib0", "mac": "auto", "link": "ib-leaf-1:swp1" }
        ],
        "metadata": { "role": "compute", "gpu": "H100x8" }
      },
      {
        "name": "dgx-h100-02",
        "os": "ubuntu-22.04",
        "cpu": 8,
        "memory": 16384,
        "interfaces": [
          { "name": "eth0", "mac": "auto", "ip": "192.168.100.12/24" },
          { "name": "ib0", "mac": "auto", "link": "ib-leaf-1:swp2" }
        ],
        "metadata": { "role": "compute", "gpu": "H100x8" }
      },
      {
        "name": "ib-leaf-1",
        "os": "cumulus-linux-5.x",
        "cpu": 4,
        "memory": 4096,
        "model": "QM9700-sim",
        "interfaces": [
          { "name": "swp1", "link": "dgx-h100-01:ib0" },
          { "name": "swp2", "link": "dgx-h100-02:ib0" },
          { "name": "swp49", "link": "ib-spine-1:swp1" },
          { "name": "swp50", "link": "ib-spine-1:swp2" }
        ],
        "metadata": { "role": "leaf-switch", "tier": "access" }
      },
      {
        "name": "ib-spine-1",
        "os": "cumulus-linux-5.x",
        "cpu": 4,
        "memory": 4096,
        "model": "QM9700-sim",
        "interfaces": [
          { "name": "swp1", "link": "ib-leaf-1:swp49" },
          { "name": "swp2", "link": "ib-leaf-1:swp50" }
        ],
        "metadata": { "role": "spine-switch", "tier": "core" }
      },
      {
        "name": "mgmt-server",
        "os": "ubuntu-22.04",
        "cpu": 4,
        "memory": 8192,
        "interfaces": [
          { "name": "eth0", "mac": "auto", "ip": "192.168.100.1/24" }
        ],
        "metadata": { "role": "management", "services": ["UFM", "OpenSM", "Ansible"] }
      }
    ],
    "links": [],
    "services": {
      "oob_network": "192.168.100.0/24",
      "ib_subnet": "192.168.200.0/24"
    }
  }
}
```

---

## AIR Lab Exercises

### Exercise 1: IB Fabric Bringup

```bash
# On mgmt-server: Install OpenSM
apt update && apt install -y opensm ibutils infiniband-diags

# Start SM
systemctl start opensm

# Verify fabric discovery
ibnetdiscover
ibstat
```

### Exercise 2: Spectrum-4 Simulation (Cumulus NVUE)

```bash
# SSH to ib-leaf-1 (Cumulus Linux)
ssh cumulus@192.168.100.20

# Configure QoS lossless (RoCEv2)
nv set qos pfc 0 tx enable on rx enable on
nv set qos map dscp-tc 26 tc 3
nv config apply

# Verify
nv show qos pfc
```

### Exercise 3: MIG Simulation (Ubuntu node)

```bash
# Install CUDA toolkit (simulated environment)
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt update && apt install -y cuda-toolkit

# Without real GPU: test MIG profile configs
cat scripts/mig/setup-mig.sh    # Review & document
```

### Exercise 4: Ansible Cluster Bootstrap

```bash
# On mgmt-server
git clone https://github.com/83avenger/nvidia-dgx-lab.git
cd nvidia-dgx-lab
pip install ansible

# Edit inventory
vi configs/air/inventory.ini

# Dry run
ansible-playbook playbooks/deploy-dgx-cluster.yml --check -i configs/air/inventory.ini
```

---

## AIR Inventory File Template

```ini
# configs/air/inventory.ini

[dgx_nodes]
dgx-h100-01 ansible_host=192.168.100.11
dgx-h100-02 ansible_host=192.168.100.12
dgx-h100-03 ansible_host=192.168.100.13

[ib_switches]
ib-leaf-1 ansible_host=192.168.100.20
ib-spine-1 ansible_host=192.168.100.21

[management]
mgmt-server ansible_host=192.168.100.1

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/air_lab_key
ansible_become=true
```

---

## PSE Demo Script (AIR)

```
1. Login to air.ngc.nvidia.com → "New Simulation"
2. Import configs/air/dgx-8node-air-topology.json
3. "Build" topology → wait ~3 min for nodes to boot
4. SSH to mgmt-server → run ./playbooks/deploy-dgx-cluster.yml
5. Demo: ibnetdiscover → fabric health
6. Demo: nvidia-smi mig -lgi → MIG profiles
7. Demo: ovs-appctl dpctl/dump-flows → DPU offload
8. Customer takeaway: "This is your Day-1 environment in AIR before hardware arrives"
```
