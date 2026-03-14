#!/bin/bash
# monitoring/prometheus/deploy-monitoring.sh
# Deploy full Prometheus + Grafana + DCGM monitoring stack on DGX K8s cluster
# Usage: ./deploy-monitoring.sh

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

NAMESPACE="monitoring"
GRAFANA_PASSWORD="NvidiaLab-$(openssl rand -hex 4)"

echo ""
echo "============================================"
echo -e "  ${CYAN}DGX Monitoring Stack Deployment${NC}"
echo "  Namespace: $NAMESPACE"
echo "============================================"

# --- Prerequisites ---
echo -e "\n${CYAN}[1/5]${NC} Checking prerequisites..."
for cmd in helm kubectl; do
  command -v "$cmd" &>/dev/null && echo "  ✓ $cmd" || { echo "  ✗ $cmd not found"; exit 1; }
done

# --- Helm repos ---
echo -e "\n${CYAN}[2/5]${NC} Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana             https://grafana.github.io/helm-charts
helm repo add nvidia              https://helm.ngc.nvidia.com/nvidia
helm repo update
echo "  ✓ Repos updated"

# --- Namespace ---
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- kube-prometheus-stack ---
echo -e "\n${CYAN}[3/5]${NC} Deploying Prometheus + Grafana + Alertmanager..."
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --set grafana.adminPassword="$GRAFANA_PASSWORD" \
  --set prometheus.prometheusSpec.scrapeInterval=15s \
  --set prometheus.prometheusSpec.evaluationInterval=30s \
  --set prometheus.prometheusSpec.retention=30d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=100Gi \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --wait --timeout 10m
echo "  ✓ Prometheus stack deployed"

# --- DCGM Exporter (GPU metrics) ---
echo -e "\n${CYAN}[4/5]${NC} Deploying DCGM Exporter for GPU metrics..."
helm upgrade --install dcgm-exporter nvidia/dcgm-exporter \
  --namespace "$NAMESPACE" \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.namespace="$NAMESPACE" \
  --set extraEnv[0].name=DCGM_EXPORTER_COLLECTORS \
  --set extraEnv[0].value="DCP" \
  --wait --timeout 5m
echo "  ✓ DCGM Exporter deployed"

# --- Apply custom alert rules ---
echo -e "\n${CYAN}[5/5]${NC} Applying DGX alert rules..."
kubectl apply -f monitoring/alerting/dgx-alerts.yml
echo "  ✓ Alert rules applied"

# --- Output access info ---
GRAFANA_SVC=$(kubectl get svc -n "$NAMESPACE" | grep grafana | awk '{print $1}' | head -1)

echo ""
echo "============================================"
echo -e "  ${GREEN}Monitoring Stack Deployed!${NC}"
echo "============================================"
echo ""
echo "  Grafana password: $GRAFANA_PASSWORD"
echo "  (Save this! It won't be shown again)"
echo ""
echo "  Access Grafana:"
echo "  kubectl port-forward svc/${GRAFANA_SVC} 3000:80 -n $NAMESPACE"
echo "  → http://localhost:3000  (admin / $GRAFANA_PASSWORD)"
echo ""
echo "  Access Prometheus:"
echo "  kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090 -n $NAMESPACE"
echo "  → http://localhost:9090"
echo ""
echo "  Recommended Dashboards to import:"
echo "    12239 — NVIDIA DCGM Exporter Dashboard"
echo "    1860  — Node Exporter Full"
echo "    15172 — Kubernetes GPU Dashboard"
echo "============================================"
