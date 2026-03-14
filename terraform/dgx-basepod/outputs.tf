# terraform/dgx-basepod/outputs.tf

output "gpu_operator_status" {
  description = "GPU Operator Helm release status"
  value       = helm_release.gpu_operator.status
}

output "namespaces_created" {
  description = "Namespaces provisioned"
  value = [
    kubernetes_namespace.gpu_operator.metadata[0].name,
    kubernetes_namespace.runai.metadata[0].name,
    kubernetes_namespace.monitoring.metadata[0].name
  ]
}

output "storage_classes" {
  description = "StorageClasses created"
  value = [
    kubernetes_storage_class.nfs_datasets.metadata[0].name,
    kubernetes_storage_class.nfs_checkpoints.metadata[0].name
  ]
}

output "cluster_summary" {
  description = "DGX BasePOD Terraform provisioning summary"
  value = {
    node_count    = length(var.dgx_node_names)
    gpu_product   = var.gpu_product
    mig_strategy  = var.mig_strategy
    fabric        = var.fabric_type
    nfs_server    = var.nfs_server
  }
}
