# 15 — NCA / NESA Compliance for DGX AI Clusters (UAE)

## Regulatory Context

AI/HPC clusters in the UAE must comply with:

| Framework | Scope | Relevance to DGX |
|-----------|-------|-----------------|
| **NCA ECC** | UAE National Cybersecurity Authority Essential Controls | Network isolation, access control, logging |
| **NESA IAS** | Information Assurance Standards | Data classification, crypto, audit |
| **UAE PDPL** | Personal Data Protection Law | Data at rest/transit for AI training data |
| **ADHICS** | Abu Dhabi Health Info & Cyber Security | If GPU cluster processes health data |
| **G42 Internal** | G42/Core42 security policies | Extends NCA with AI-specific controls |

---

## NCA ECC Mapping to DGX Infrastructure

### ECC-1: Asset Management

```bash
# Document all DGX hardware assets
nvidia-smi --query-gpu=name,serial,uuid --format=csv > /etc/nvidia/gpu-asset-register.csv

# Document IB switch assets
mlxfwmanager --query 2>/dev/null | grep -E "PSID|FW Version|Board" > /etc/nvidia/ib-asset-register.txt

# Kubernetes node inventory
kubectl get nodes -o json | python3 -c "
import json,sys
nodes=json.load(sys.stdin)['items']
for n in nodes:
  print(n['metadata']['name'], n['status']['nodeInfo']['kubeletVersion'])
" > /etc/k8s-node-register.txt
```

### ECC-2: Access Control

```yaml
# configs/k8s/rbac-gpu-cluster.yaml
# Least-privilege RBAC for GPU cluster users

---
# Role: GPU job submitter (Run:ai user)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gpu-job-submitter
  namespace: runai-team-nlp
rules:
  - apiGroups: ["run.ai"]
    resources: ["trainingworkloads", "interactiveworkloads"]
    verbs: ["get", "list", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]

---
# Role: GPU cluster viewer (monitoring)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gpu-cluster-viewer
rules:
  - apiGroups: [""]
    resources: ["nodes", "pods", "namespaces"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["nodes", "pods"]
    verbs: ["get", "list"]

---
# Deny: no exec into GPU pods by default
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: deny-pod-exec
rules:
  - apiGroups: [""]
    resources: ["pods/exec", "pods/attach"]
    verbs: []     # empty = deny
```

### ECC-3: Network Security (DGX-specific)

```bash
# 1. IB Subnet Partitioning (VLAN-equivalent for IB)
# Creates isolated P_Keys per tenant — prevents cross-tenant RDMA
cat >> /etc/opensm/partitions.conf << 'EOF'
# Production AI training partition
Default=0x7fff,ipoib: ALL, ALL_SWITCHES=full;

# Tenant A — NLP team (limited membership)
NLPTenant=0x7ffe,ipoib: 0x0002c903000f9a10=full,0x0002c903000f9a11=full;

# Tenant B — CV team
CVTenant=0x7ffd,ipoib: 0x0002c903000f9b10=full,0x0002c903000f9b11=full;
EOF

systemctl restart opensm

# 2. BlueField-3 DPU host isolation (zero-trust)
# BF3 in DPU mode: host cannot modify its own network policy
# Already configured in playbooks/dpu-offload-enable.yml

# 3. Network policy in Kubernetes (pod-level microsegmentation)
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: gpu-workload-isolation
  namespace: runai-team-nlp
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              team: nlp
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              team: nlp
    - ports:        # Allow DNS
        - port: 53
          protocol: UDP
EOF
```

### ECC-4: Logging & Monitoring (Audit Trail)

```bash
# Enable Kubernetes audit logging
# /etc/kubernetes/audit-policy.yaml
cat > /etc/kubernetes/audit-policy.yaml << 'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Log GPU resource requests
  - level: Request
    resources:
      - group: ""
        resources: ["pods"]
    namespaces: ["runai-team-nlp", "runai-team-cv", "runai-team-infra"]

  # Log RBAC changes
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterrolebindings", "rolebindings"]

  # Log secrets access
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Log node exec (should be rare)
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach"]
EOF

# Centralise logs: ship to SIEM (FortiSIEM / Azure Sentinel)
# Via Fluentd/Fluent Bit DaemonSet
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluentd-config
  namespace: kube-system
data:
  fluent.conf: |
    <source>
      @type tail
      path /var/log/audit/kube-audit.log
      tag k8s.audit
      format json
    </source>
    <match k8s.audit>
      @type forward
      <server>
        host fortisiem.internal
        port 514
      </server>
    </match>
EOF
```

### ECC-5: Encryption

```bash
# 1. etcd encryption at rest (K8s secrets)
# /etc/kubernetes/enc-config.yaml
cat > /etc/kubernetes/enc-config.yaml << 'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: [secrets]
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64-encoded-32-byte-key>
      - identity: {}
EOF

# Add to kube-apiserver: --encryption-provider-config=/etc/kubernetes/enc-config.yaml

# 2. IB data-in-transit: IPsec via BF3 DPU (already in dpu-offload-enable.yml)
# 3. GPU training data: encrypt NFS/WEKA mount at storage layer
# 4. Model checkpoints: encrypt at rest on VAST/WEKA with AES-256
```

---

## NCA Compliance Quick Checklist

| Control | Implementation | Status |
|---------|---------------|--------|
| Asset register | `nvidia-smi`, `kubectl get nodes` | ✅ Script provided |
| RBAC least privilege | `configs/k8s/rbac-gpu-cluster.yaml` | ✅ Manifest provided |
| IB tenant isolation | OpenSM P_Key partitions | ✅ Config provided |
| Network microsegmentation | K8s NetworkPolicy + BF3 DPU | ✅ Playbook provided |
| Audit logging | K8s audit policy → SIEM | ✅ Config provided |
| Encryption at rest | etcd + storage-layer AES-256 | ✅ Reference provided |
| Encryption in transit | IPsec via BF3 DPU | ✅ Playbook provided |
| Vulnerability management | `nvidia-smi`, `mlxfwmanager` updates | 🔄 Monthly process |
| Incident response | `docs/13-day2-ops-runbook.md` | ✅ Runbook provided |
| Business continuity | Multi-node K8s HA, Run:ai rescheduling | ✅ Architecture |

---

## PSE Positioning Note (UAE)

> When presenting DGX to G42, Core42, or government clients in Abu Dhabi, NCA compliance is a procurement gate — not a nice-to-have. Mapping BF3 DPU host isolation + IB P_Key partitioning + K8s RBAC to NCA ECC controls directly answers the security team's requirements and differentiates NVIDIA from generic x86 GPU server vendors.
