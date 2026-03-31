# 10 — Monitoring: Prometheus + Grafana + DCGM for DGX Clusters

## Stack Overview

```
DGX Node                     Monitoring Stack
──────────────               ──────────────────────────────
nvidia-dcgm-exporter  ──────► Prometheus ──► Grafana Dashboards
node_exporter         ──────►             ──► Alertmanager
mlx5_exporter (IB)    ──────►             ──► PagerDuty / Slack
```

| Component | Purpose |
|-----------|---------|
| **DCGM Exporter** | GPU metrics: utilization, temp, power, memory, NVLink errors |
| **Node Exporter** | CPU, RAM, disk, network per node |
| **MLX5 / IB Exporter** | InfiniBand port counters, error rates |
| **Prometheus** | Time-series scraping and storage |
| **Grafana** | Dashboards, alerting UI |
| **Alertmanager** | Route alerts to Slack/email/PagerDuty |

---

## DCGM Exporter (GPU Metrics)

```bash
# Install via Helm (part of GPU Operator)
helm install gpu-operator nvidia/gpu-operator \
  --set dcgm-exporter.enabled=true \
  --namespace gpu-operator

# Standalone install
docker run -d --gpus all \
  --cap-add SYS_ADMIN \
  -p 9400:9400 \
  nvcr.io/nvidia/k8s/dcgm-exporter:3.3.0-3.2.0-ubuntu22.04

# Test metrics
curl http://localhost:9400/metrics | grep -E "DCGM_FI_DEV_GPU_UTIL|DCGM_FI_DEV_MEM_COPY_UTIL|DCGM_FI_DEV_POWER_USAGE"
```

### Key DCGM Metrics

| Metric | Description | Alert Threshold |
|--------|-------------|-----------------|
| `DCGM_FI_DEV_GPU_UTIL` | GPU SM utilization % | < 20% (idle waste) |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | Memory bandwidth utilization % | — |
| `DCGM_FI_DEV_POWER_USAGE` | Power draw (W) | > 750W (H100 TDP) |
| `DCGM_FI_DEV_GPU_TEMP` | GPU temperature (°C) | > 83°C |
| `DCGM_FI_DEV_FB_USED` | HBM used (MB) | > 95% capacity |
| `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL` | NVLink bandwidth | Drop vs baseline |
| `DCGM_FI_DEV_XID_ERRORS` | GPU XID error count | > 0 (critical) |

---

## Prometheus Configuration

```yaml
# monitoring/prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 30s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

rule_files:
  - "/etc/prometheus/rules/dgx-alerts.yml"

scrape_configs:
  # DCGM GPU metrics from all DGX nodes
  - job_name: dcgm-exporter
    static_configs:
      - targets:
          - "192.168.100.11:9400"
          - "192.168.100.12:9400"
          - "192.168.100.13:9400"
          - "192.168.100.14:9400"
          - "192.168.100.15:9400"
          - "192.168.100.16:9400"
          - "192.168.100.17:9400"
          - "192.168.100.18:9400"
    relabel_configs:
      - source_labels: [__address__]
        regex: "(.*):[0-9]+"
        target_label: node_ip

  # Node exporter — CPU/RAM/disk per DGX node
  - job_name: node-exporter
    static_configs:
      - targets:
          - "192.168.100.11:9100"
          - "192.168.100.12:9100"
          - "192.168.100.13:9100"
          - "192.168.100.14:9100"
          - "192.168.100.15:9100"
          - "192.168.100.16:9100"
          - "192.168.100.17:9100"
          - "192.168.100.18:9100"

  # Kubernetes API metrics (for Run:ai job tracking)
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"

  # Prometheus self-scrape
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
```

---

## Alert Rules

```yaml
# monitoring/alerting/dgx-alerts.yml
groups:
  - name: dgx-gpu-alerts
    rules:

      - alert: GPUHighTemperature
        expr: DCGM_FI_DEV_GPU_TEMP > 85
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "GPU overheating on {{ $labels.instance }}"
          description: "GPU {{ $labels.gpu }} temperature is {{ $value }}°C (threshold: 85°C)"

      - alert: GPUXIDError
        expr: increase(DCGM_FI_DEV_XID_ERRORS[5m]) > 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "GPU XID error on {{ $labels.instance }}"
          description: "XID error detected on GPU {{ $labels.gpu }} — check nvidia-smi dmon"

      - alert: GPULowUtilization
        expr: DCGM_FI_DEV_GPU_UTIL < 10
        for: 30m
        labels:
          severity: info
        annotations:
          summary: "GPU idle on {{ $labels.instance }}"
          description: "GPU {{ $labels.gpu }} has been < 10% utilized for 30 minutes"

      - alert: GPUMemoryNearFull
        expr: (DCGM_FI_DEV_FB_USED / DCGM_FI_DEV_FB_TOTAL) * 100 > 95
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "GPU memory near capacity on {{ $labels.instance }}"
          description: "GPU {{ $labels.gpu }} memory {{ $value | printf \"%.1f\" }}% full"

      - alert: GPUPowerLimit
        expr: DCGM_FI_DEV_POWER_USAGE > 750
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "GPU power over TDP on {{ $labels.instance }}"
          description: "GPU {{ $labels.gpu }} drawing {{ $value }}W (H100 TDP: 700W)"

  - name: dgx-node-alerts
    rules:

      - alert: NodeHighCPU
        expr: 100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage on DGX node {{ $labels.instance }}"

      - alert: NodeMemoryPressure
        expr: (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 5
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Memory pressure on {{ $labels.instance }}"

      - alert: IBPortError
        expr: increase(infiniband_port_data_symbols_error_total[5m]) > 100
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "IB symbol errors on {{ $labels.instance }}"
          description: "Port {{ $labels.port }} has {{ $value }} symbol errors — check cable"
```

---

## Alertmanager: Slack Routing

```yaml
# monitoring/alerting/alertmanager.yml
global:
  resolve_timeout: 5m
  slack_api_url: "https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK"

route:
  group_by: ["alertname", "instance"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: slack-dgx-ops

  routes:
    - match:
        severity: critical
      receiver: slack-dgx-critical
      repeat_interval: 1h

receivers:
  - name: slack-dgx-ops
    slack_configs:
      - channel: "#dgx-cluster-ops"
        title: "DGX Cluster Alert: {{ .GroupLabels.alertname }}"
        text: "{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}"

  - name: slack-dgx-critical
    slack_configs:
      - channel: "#dgx-critical"
        title: "🚨 CRITICAL: {{ .GroupLabels.alertname }}"
        text: "{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}"
```

---

## Grafana Dashboard: GPU Cluster Overview

```bash
# Deploy Grafana + import NVIDIA dashboards
helm install grafana grafana/grafana \
  --namespace monitoring \
  --set adminPassword=NvidiaLab123 \
  --set service.type=NodePort

# Import NVIDIA DCGM dashboard
# Dashboard ID: 12239 (DCGM Exporter Dashboard)
# Import at: Grafana → Dashboards → Import → ID: 12239

# Import Node Exporter dashboard
# Dashboard ID: 1860
```

### Grafana Dashboard JSON Snippet (GPU Utilization Panel)

```json
{
  "title": "GPU Cluster Utilization",
  "panels": [
    {
      "title": "GPU Utilization per Node",
      "type": "timeseries",
      "targets": [
        {
          "expr": "avg by (instance, gpu) (DCGM_FI_DEV_GPU_UTIL)",
          "legendFormat": "{{ instance }} GPU{{ gpu }}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "steps": [
              { "value": 0, "color": "red" },
              { "value": 20, "color": "yellow" },
              { "value": 70, "color": "green" }
            ]
          }
        }
      }
    }
  ]
}
```

---

## Deploy Full Stack with Helm

```bash
# monitoring/prometheus/deploy.sh
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Deploy kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=NvidiaLab123 \
  --set prometheus.prometheusSpec.scrapeInterval=15s \
  -f monitoring/prometheus/prometheus.yml

echo "Grafana: kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring"
echo "Prometheus: kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090 -n monitoring"
```
