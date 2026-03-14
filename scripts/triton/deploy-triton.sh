#!/bin/bash
# scripts/triton/deploy-triton.sh
# Deploy NVIDIA Triton Inference Server on DGX K8s cluster
# Usage: ./deploy-triton.sh --namespace inference --replicas 2 --gpus 2

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

NAMESPACE="inference"
REPLICAS=2
GPUS_PER_POD=2
TRITON_IMAGE="nvcr.io/nvidia/tritonserver:24.01-py3"
MODEL_PVC="model-store-pvc"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --replicas)  REPLICAS="$2"; shift 2 ;;
    --gpus)      GPUS_PER_POD="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo ""
echo "============================================"
echo -e "  ${CYAN}Triton Inference Server Deployment${NC}"
echo "  Namespace: $NAMESPACE | Replicas: $REPLICAS | GPUs: $GPUS_PER_POD"
echo "============================================"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Apply Deployment
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton-inference-server
  namespace: ${NAMESPACE}
  labels:
    app: triton
    version: "24.01"
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: triton
  template:
    metadata:
      labels:
        app: triton
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8002"
        prometheus.io/path: "/metrics"
    spec:
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: triton
          image: ${TRITON_IMAGE}
          args:
            - tritonserver
            - --model-repository=/models
            - --grpc-port=8001
            - --http-port=8000
            - --metrics-port=8002
            - --allow-metrics=true
            - --log-verbose=0
            - --model-control-mode=explicit
            - --load-model=bert-large
          ports:
            - name: http
              containerPort: 8000
            - name: grpc
              containerPort: 8001
            - name: metrics
              containerPort: 8002
          resources:
            limits:
              nvidia.com/gpu: "${GPUS_PER_POD}"
              memory: "128Gi"
              cpu: "16"
            requests:
              nvidia.com/gpu: "${GPUS_PER_POD}"
              memory: "32Gi"
              cpu: "4"
          readinessProbe:
            httpGet:
              path: /v2/health/ready
              port: 8000
            initialDelaySeconds: 45
            periodSeconds: 15
            failureThreshold: 5
          livenessProbe:
            httpGet:
              path: /v2/health/live
              port: 8000
            initialDelaySeconds: 60
            periodSeconds: 30
          volumeMounts:
            - name: model-store
              mountPath: /models
            - name: shm
              mountPath: /dev/shm
      volumes:
        - name: model-store
          persistentVolumeClaim:
            claimName: ${MODEL_PVC}
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 32Gi
---
apiVersion: v1
kind: Service
metadata:
  name: triton-service
  namespace: ${NAMESPACE}
  labels:
    app: triton
spec:
  selector:
    app: triton
  ports:
    - name: http
      port: 8000
      targetPort: 8000
    - name: grpc
      port: 8001
      targetPort: 8001
    - name: metrics
      port: 8002
      targetPort: 8002
  type: ClusterIP
EOF

echo -e "\n${CYAN}[INFO]${NC} Waiting for Triton pods to be ready..."
kubectl rollout status deployment/triton-inference-server -n "$NAMESPACE" --timeout=300s

echo ""
echo -e "${GREEN}[DONE]${NC} Triton deployed in namespace: $NAMESPACE"
echo ""
echo "  Test health:"
echo "  kubectl port-forward svc/triton-service 8000:8000 -n $NAMESPACE"
echo "  curl http://localhost:8000/v2/health/ready"
echo ""
echo "  List models:"
echo "  curl http://localhost:8000/v2/models"
