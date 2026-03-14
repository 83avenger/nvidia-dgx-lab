# terraform/dgx-basepod/variables.tf

variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubernetes context name"
  type        = string
  default     = "dgx-basepod"
}

variable "gpu_operator_version" {
  description = "NVIDIA GPU Operator Helm chart version"
  type        = string
  default     = "v23.9.0"
}

variable "mig_strategy" {
  description = "MIG strategy: none, single, mixed"
  type        = string
  default     = "mixed"
  validation {
    condition     = contains(["none", "single", "mixed"], var.mig_strategy)
    error_message = "mig_strategy must be: none, single, or mixed"
  }
}

variable "mig_enabled" {
  description = "Enable MIG Manager in GPU Operator"
  type        = string
  default     = "true"
}

variable "dgx_node_names" {
  description = "List of DGX Kubernetes node names"
  type        = list(string)
  default = [
    "dgx-h100-01",
    "dgx-h100-02",
    "dgx-h100-03",
    "dgx-h100-04",
    "dgx-h100-05",
    "dgx-h100-06",
    "dgx-h100-07",
    "dgx-h100-08"
  ]
}

variable "gpu_product" {
  description = "NVIDIA GPU product label"
  type        = string
  default     = "NVIDIA-H100-SXM5-80GB"
}

variable "fabric_type" {
  description = "Network fabric type: infiniband or spectrum-x"
  type        = string
  default     = "infiniband"
}

variable "nfs_server" {
  description = "NFS server IP for storage"
  type        = string
  default     = "192.168.50.10"
}

variable "nfs_dataset_path" {
  description = "NFS export path for datasets"
  type        = string
  default     = "/exports/datasets"
}

variable "nfs_checkpoint_path" {
  description = "NFS export path for model checkpoints"
  type        = string
  default     = "/exports/checkpoints"
}
