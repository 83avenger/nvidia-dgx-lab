# 11 — NVIDIA Triton Inference Server: Deployment on DGX

## What is Triton?

NVIDIA Triton Inference Server is the **production inference platform** for deploying ML models at scale on GPU clusters. It supports:

- **Multiple frameworks**: TensorRT, PyTorch TorchScript, ONNX, TensorFlow SavedModel, OpenVINO
- **Dynamic batching**: auto-batches concurrent requests to maximize GPU utilization
- **Multi-model serving**: hundreds of models on one GPU cluster simultaneously
- **MIG-aware**: deploy models to specific MIG slices
- **gRPC + HTTP API**: standard REST and gRPC endpoints

---

## Triton on DGX: Architecture

```
Client (HTTP/gRPC)
        │
        ▼
┌─────────────────────────────────────┐
│      Triton Inference Server        │
│   (Pod on Kubernetes / DGX Node)    │
│                                     │
│  ┌───────────┐  ┌───────────────┐   │
│  │ Model A   │  │   Model B     │   │
│  │ TensorRT  │  │  PyTorch      │   │
│  │ GPU: MIG  │  │  GPU: Full    │   │
│  └───────────┘  └───────────────┘   │
│                                     │
│  Dynamic Batcher | Ensemble | DALI  │
└────────────────┬────────────────────┘
                 │
         NVIDIA GPU (H100)
                 │
         NVMe Model Store / NFS
```

---

## Model Repository Layout

```
/models/
├── bert-large/
│   ├── config.pbtxt
│   └── 1/
│       └── model.plan          # TensorRT engine
├── llama2-7b/
│   ├── config.pbtxt
│   └── 1/
│       └── model.pt            # TorchScript
└── yolov8/
    ├── config.pbtxt
    └── 1/
        └── model.onnx
```

---

## Model Config: BERT-Large TensorRT

```protobuf
# configs/triton/bert-large-config.pbtxt
name: "bert-large"
platform: "tensorrt_plan"
max_batch_size: 32

input [
  {
    name: "input_ids"
    data_type: TYPE_INT32
    dims: [128]
  },
  {
    name: "attention_mask"
    data_type: TYPE_INT32
    dims: [128]
  }
]

output [
  {
    name: "logits"
    data_type: TYPE_FP32
    dims: [2]
  }
]

dynamic_batching {
  preferred_batch_size: [8, 16, 32]
  max_queue_delay_microseconds: 500
}

instance_group [
  {
    count: 2
    kind: KIND_GPU
    gpus: [0]              # Run on GPU 0 (or MIG slice)
  }
]
```

---

## Model Config: LLaMA-2 7B vLLM Backend

```protobuf
# configs/triton/llama2-7b-config.pbtxt
name: "llama2-7b"
backend: "vllm"
max_batch_size: 0    # vLLM manages batching internally

model_transaction_policy {
  decoupled: true    # Streaming responses
}

input [
  {
    name: "text_input"
    data_type: TYPE_STRING
    dims: [1]
  },
  {
    name: "max_tokens"
    data_type: TYPE_INT32
    dims: [1]
    optional: true
  }
]

output [
  {
    name: "text_output"
    data_type: TYPE_STRING
    dims: [1]
  }
]

parameters {
  key: "model"
  value: { string_value: "meta-llama/Llama-2-7b-chat-hf" }
}
parameters {
  key: "gpu_memory_utilization"
  value: { string_value: "0.85" }
}
parameters {
  key: "tensor_parallel_size"
  value: { string_value: "1" }
}
```

---

## Deploy Triton on Kubernetes (DGX)

```yaml
# configs/k8s/triton-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton-inference-server
  namespace: inference
spec:
  replicas: 2
  selector:
    matchLabels:
      app: triton
  template:
    metadata:
      labels:
        app: triton
    spec:
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: triton
          image: nvcr.io/nvidia/tritonserver:24.01-py3
          args:
            - tritonserver
            - --model-repository=/models
            - --grpc-port=8001
            - --http-port=8000
            - --metrics-port=8002
            - --log-verbose=1
          ports:
            - containerPort: 8000   # HTTP
            - containerPort: 8001   # gRPC
            - containerPort: 8002   # Metrics (Prometheus)
          resources:
            limits:
              nvidia.com/gpu: "2"
              memory: "128Gi"
              cpu: "16"
          readinessProbe:
            httpGet:
              path: /v2/health/ready
              port: 8000
            initialDelaySeconds: 30
            periodSeconds: 10
          volumeMounts:
            - name: model-store
              mountPath: /models
            - name: shm
              mountPath: /dev/shm
      volumes:
        - name: model-store
          persistentVolumeClaim:
            claimName: model-store-pvc
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 32Gi
---
apiVersion: v1
kind: Service
metadata:
  name: triton-service
  namespace: inference
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
```

---

## Triton CLI: Model Management & Testing

```bash
# Check server health
curl http://triton-service:8000/v2/health/live
curl http://triton-service:8000/v2/health/ready

# List loaded models
curl http://triton-service:8000/v2/models

# Get model metadata
curl http://triton-service:8000/v2/models/bert-large

# Load / unload model dynamically
curl -X POST http://triton-service:8000/v2/repository/models/bert-large/load
curl -X POST http://triton-service:8000/v2/repository/models/bert-large/unload

# Run inference (HTTP)
curl -X POST http://triton-service:8000/v2/models/bert-large/infer \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": [
      {"name": "input_ids", "shape": [1, 128], "datatype": "INT32", "data": [101,2054,0,...]},
      {"name": "attention_mask", "shape": [1, 128], "datatype": "INT32", "data": [1,1,0,...]}
    ]
  }'

# Performance benchmark with perf_analyzer
perf_analyzer \
  -m bert-large \
  -u triton-service:8001 \
  --concurrency-range 1:16 \
  --measurement-interval 10000 \
  --protocol grpc
```

---

## Triton + MIG: Per-Slice Inference

```protobuf
# Assign model instance to specific MIG slice
instance_group [
  {
    count: 1
    kind: KIND_GPU
    gpus: [0]    # MIG GI 0
  },
  {
    count: 1
    kind: KIND_GPU
    gpus: [1]    # MIG GI 1
  }
]
```

```bash
# Check Triton is using MIG slices correctly
nvidia-smi mig -lgi     # confirm GI active
curl http://localhost:8000/v2/models/bert-large | jq '.backend'
```

---

## PSE Key Metrics: Triton Performance

| Metric | Tool | Target (BERT-Large, H100) |
|--------|------|--------------------------|
| Throughput | `perf_analyzer` | >5,000 req/s @ batch=32 |
| Latency p99 | `perf_analyzer` | <10ms @ batch=1 |
| GPU Utilization | `nvidia-smi dmon` | >80% sustained |
| Dynamic batch efficiency | Triton metrics | >90% preferred batch hits |

```bash
# Monitor Triton metrics via Prometheus
curl http://triton-service:8002/metrics | grep -E "nv_inference|nv_gpu"
# Key: nv_inference_request_success, nv_gpu_utilization, nv_inference_queue_duration_us
```
