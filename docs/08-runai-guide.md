# 08 — Run:ai: GPU Scheduling & Orchestration for DGX Clusters

## What is Run:ai?

Run:ai is NVIDIA's **AI workload orchestration platform** built on Kubernetes. It provides:
- **GPU fractional scheduling** — share GPUs across jobs without MIG
- **GPU quotas per project/team** — guaranteed + burst allocation
- **Gang scheduling** — all-or-nothing allocation for distributed training
- **Queue fairness** — preemption, priority, FIFO across teams
- **MIG-aware scheduling** — integrates with GPU Operator MIG profiles
- **Visibility** — real-time GPU utilization dashboards

> Run:ai replaces raw `kubectl` GPU requests with a higher-level abstraction. It's the standard scheduler for NVIDIA DGX BasePOD and SuperPOD deployments.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Run:ai Control Plane                  │
│         (SaaS at app.run.ai or self-hosted)             │
└──────────────────────┬──────────────────────────────────┘
                       │ Kubernetes API
┌──────────────────────▼──────────────────────────────────┐
│                  Kubernetes Cluster                       │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │             Run:ai Scheduler (pod)               │   │
│  │  - Fractional GPU         - Gang Scheduling      │   │
│  │  - Quota enforcement      - Preemption           │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐             │
│  │ DGX Node │  │ DGX Node │  │ DGX Node │             │
│  │ 8x H100  │  │ 8x H100  │  │ 8x H100  │             │
│  └──────────┘  └──────────┘  └──────────┘             │
└─────────────────────────────────────────────────────────┘
```

---

## Installation

```bash
# 1. Add Run:ai Helm repo
helm repo add runai https://runai.jfrog.io/artifactory/cp-charts-prod
helm repo update

# 2. Install Run:ai Cluster (connects to Run:ai SaaS)
helm install runai-cluster runai/runai-cluster \
  --namespace runai \
  --create-namespace \
  --set controlPlane.url=https://app.run.ai \
  --set controlPlane.clientId=<CLIENT_ID> \
  --set controlPlane.clientSecret=<CLIENT_SECRET> \
  --set cluster.uid=<CLUSTER_UID>

# 3. Verify pods
kubectl get pods -n runai
# Expected: runai-scheduler, runai-agent, gpu-device-plugin, ...

# 4. Install Run:ai CLI
wget https://app.run.ai/cli/runai-cli-linux-amd64.tar.gz
tar -xzf runai-cli-linux-amd64.tar.gz
mv runai /usr/local/bin/
runai login
```

---

## Core Concepts

| Concept | Description |
|---------|-------------|
| **Project** | Namespace-level resource group with GPU quota |
| **Department** | Group of Projects (team/BU level) |
| **Quota** | Guaranteed GPUs for a project |
| **Over-quota** | Burst above quota when cluster has idle GPUs |
| **Preemption** | Low-priority jobs evicted to free GPUs for high-priority |
| **Gang** | Multi-node job — all workers start together or wait |
| **Interactive** | Long-running session (Jupyter, SSH) — not preemptible |
| **Training** | Batch job — preemptible, checkpointed |

---

## GPU Fraction Scheduling

Run:ai allows jobs to request fractions of a GPU (memory-based):

```bash
# Request 25% of one GPU (no MIG needed)
runai submit frac-job \
  --project team-nlp \
  --image nvcr.io/nvidia/cuda:12.3-runtime-ubuntu22.04 \
  --gpu 0.25 \
  -- python inference.py

# Request 2.5 GPUs (fraction across physical GPUs)
runai submit big-inference \
  --project team-nlp \
  --image nvcr.io/nvidia/tritonserver:24.01-py3 \
  --gpu 2.5 \
  -- tritonserver --model-repository=/models
```

---

## Distributed Training (Gang Scheduling)

```bash
# 4-node distributed training — PyTorch DDP
runai submit-dist pytorch \
  --name llama-train \
  --project team-llm \
  --workers 4 \
  --gpu 8 \
  --image nvcr.io/nvidia/pytorch:24.01-py3 \
  --large-shm \
  -- torchrun --nproc_per_node=8 train.py \
       --model llama-70b \
       --dataset /data/pile

# Monitor
runai describe job llama-train
runai logs llama-train --worker 0
```

---

## PSE Quick Reference: Run:ai CLI

```bash
# List all jobs
runai list jobs -A

# Get job details + GPU allocation
runai describe job <name> -p <project>

# Check GPU utilization per job
runai top job

# Check cluster GPU summary
runai cluster info

# Delete job
runai delete job <name> -p <project>

# List projects + quotas
runai list projects

# Watch logs in real time
runai logs <job> -f
```
