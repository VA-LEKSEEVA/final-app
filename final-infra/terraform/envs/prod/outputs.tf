output "nodes" {
  description = "Cluster nodes consumed by scripts/generate-inventory.sh."
  value = [
    for name in sort(keys(yandex_compute_instance.node)) : {
      name       = name
      role       = local.nodes[name].role
      public_ip  = yandex_compute_instance.node[name].network_interface[0].nat_ip_address
      private_ip = yandex_compute_instance.node[name].network_interface[0].ip_address
    }
  ]
}

output "server_public_ip" {
  description = "Public IP used by kubeconfig and SSH."
  value       = yandex_compute_instance.node["server-1"].network_interface[0].nat_ip_address
}

output "app_public_ip" {
  description = "Public IP used by the application hostname (load balancer or server fallback)."
  value       = local.app_public_ip
}

output "ssh_user" {
  value = var.ssh_user
}

output "ssh_private_key_path" {
  value = pathexpand(var.ssh_private_key_path)
}

output "ssh_private_key_pem" {
  value     = tls_private_key.cluster.private_key_openssh
  sensitive = true
}

output "backup_bucket" {
  value = try(yandex_storage_bucket.backup[0].bucket, null)
}

output "backup_s3_endpoint" {
  value = "https://storage.yandexcloud.net"
}

output "backup_access_key" {
  value     = try(yandex_iam_service_account_static_access_key.backup[0].access_key, null)
  sensitive = true
}

output "backup_secret_key" {
  value     = try(yandex_iam_service_account_static_access_key.backup[0].secret_key, null)
  sensitive = true
}

output "backup_namespace" {
  value = var.backup_namespace
}

output "backup_secret_name" {
  value = var.backup_secret_name
}

output "backup_cronjob_name" {
  value = var.backup_cronjob_name
}
