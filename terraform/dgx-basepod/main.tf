# terraform/dgx-basepod/main.tf
# Terraform: DGX BasePOD infrastructure provisioning
# Provisions: K8s node labels, namespaces, RBAC, storage classes, GPU Operator
# Assumes: K8s cluster already running on DGX nodes (use for Day-1 config)

terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

# -----------------------------------------------
# Namespaces
# -----------------------------------------------
resource "kubernetes_namespace" "gpu_operator" {
  metadata {
    name = "gpu-operator"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_namespace" "runai" {
  metadata {
    name = "runai"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# -----------------------------------------------
# GPU Operator (DCGM + MIG Manager + Device Plugin)
# -----------------------------------------------
resource "helm_release" "gpu_operator" {
  name       = "gpu-operator"
  repository = "https://helm.ngc.nvidia.com/nvidia"
  chart      = "gpu-operator"
  version    = var.gpu_operator_version
  namespace  = kubernetes_namespace.gpu_operator.metadata[0].name

  set {
    name  = "mig.strategy"
    value = var.mig_strategy   # "none", "single", or "mixed"
  }

  set {
    name  = "dcgm-exporter.enabled"
    value = "true"
  }

  set {
    name  = "driver.enabled"
    value = "false"   # Drivers pre-installed on DGX OS
  }

  set {
    name  = "toolkit.enabled"
    value = "true"
  }

  set {
    name  = "devicePlugin.enabled"
    value = "true"
  }

  set {
    name  = "migManager.enabled"
    value = var.mig_enabled
  }

  depends_on = [kubernetes_namespace.gpu_operator]
}

# -----------------------------------------------
# Node Labels: GPU type & role
# -----------------------------------------------
resource "kubernetes_labels" "dgx_nodes" {
  for_each = toset(var.dgx_node_names)

  api_version = "v1"
  kind        = "Node"

  metadata {
    name = each.value
  }

  labels = {
    "nvidia.com/gpu.present"   = "true"
    "nvidia.com/gpu.product"   = var.gpu_product   # e.g. "NVIDIA-H100-SXM5-80GB"
    "node-role"                = "dgx-compute"
    "fabric"                   = var.fabric_type    # "infiniband" or "spectrum-x"
  }
}

# -----------------------------------------------
# Storage: NFS StorageClass for checkpoints/datasets
# -----------------------------------------------
resource "kubernetes_storage_class" "nfs_datasets" {
  metadata {
    name = "nfs-datasets"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner    = "nfs.csi.k8s.io"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    server = var.nfs_server
    share  = var.nfs_dataset_path
  }
}

resource "kubernetes_storage_class" "nfs_checkpoints" {
  metadata {
    name = "nfs-checkpoints"
  }

  storage_provisioner    = "nfs.csi.k8s.io"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    server = var.nfs_server
    share  = var.nfs_checkpoint_path
  }
}

# -----------------------------------------------
# RBAC: GPU Operator service account
# -----------------------------------------------
resource "kubernetes_cluster_role_binding" "gpu_operator_admin" {
  metadata {
    name = "gpu-operator-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "gpu-operator"
    namespace = kubernetes_namespace.gpu_operator.metadata[0].name
  }

  depends_on = [helm_release.gpu_operator]
}
