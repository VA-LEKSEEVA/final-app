provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = var.zone
}

locals {
  nodes = {
    server-1 = {
      role     = "server"
      local_ip = cidrhost(var.subnet_cidr, 10)
    }
    agent-1 = {
      role     = "agent"
      local_ip = cidrhost(var.subnet_cidr, 11)
    }
    agent-2 = {
      role     = "agent"
      local_ip = cidrhost(var.subnet_cidr, 12)
    }
  }

  common_labels = merge(
    {
      managed_by = "terraform"
      project    = "final-infra"
      cluster    = var.cluster_name
    },
    var.labels
  )

  effective_cloud_id  = var.cloud_id != null && var.cloud_id != "" ? var.cloud_id : data.yandex_client_config.current.cloud_id
  effective_folder_id = var.folder_id != null && var.folder_id != "" ? var.folder_id : data.yandex_client_config.current.folder_id
  ssh_public_key = var.ssh_public_key_path != null && var.ssh_public_key_path != "" ? trimspace(
    file(pathexpand(var.ssh_public_key_path))
  ) : trimspace(tls_private_key.cluster.public_key_openssh)
  subnet_id = var.use_existing_network ? var.existing_subnet_id : yandex_vpc_subnet.cluster[0].id
  security_group_ids = var.use_existing_network ? var.existing_security_group_ids : [
    yandex_vpc_security_group.cluster[0].id
  ]
  app_public_ip = var.manage_load_balancer ? one([
    for listener in yandex_lb_network_load_balancer.ingress[0].listener :
    one(listener.external_address_spec).address
    if listener.name == "http"
  ]) : yandex_compute_instance.node["server-1"].network_interface[0].nat_ip_address
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "tls_private_key" "cluster" {
  algorithm = "ED25519"
}

resource "yandex_vpc_network" "cluster" {
  count = var.use_existing_network ? 0 : 1

  name      = var.network_name
  folder_id = local.effective_folder_id
  labels    = local.common_labels
}

resource "yandex_vpc_subnet" "cluster" {
  count = var.use_existing_network ? 0 : 1

  name           = "${var.network_name}-${var.zone}"
  folder_id      = local.effective_folder_id
  zone           = var.zone
  network_id     = yandex_vpc_network.cluster[0].id
  v4_cidr_blocks = [var.subnet_cidr]
  labels         = local.common_labels
}

resource "yandex_vpc_security_group" "cluster" {
  count = var.use_existing_network ? 0 : 1

  name       = "${var.cluster_name}-sg"
  folder_id  = local.effective_folder_id
  network_id = yandex_vpc_network.cluster[0].id
  labels     = local.common_labels

  ingress {
    protocol       = "TCP"
    description    = "SSH administration"
    port           = 22
    v4_cidr_blocks = var.admin_cidrs
  }

  ingress {
    protocol       = "TCP"
    description    = "HTTP ingress"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol       = "TCP"
    description    = "HTTPS ingress"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol       = "TCP"
    description    = "Network Load Balancer health checks"
    from_port      = 80
    to_port        = 443
    v4_cidr_blocks = ["198.18.235.0/24", "198.18.248.0/24"]
  }

  ingress {
    protocol       = "TCP"
    description    = "Kubernetes API for cluster administration"
    port           = 6443
    v4_cidr_blocks = var.admin_cidrs
  }

  ingress {
    protocol          = "ANY"
    description       = "All traffic between cluster nodes"
    predefined_target = "self_security_group"
  }

  egress {
    protocol       = "ANY"
    description    = "Internet access for installation and image pulls"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

data "yandex_compute_image" "ubuntu" {
  family = var.ubuntu_image_family
}

resource "yandex_compute_instance" "node" {
  for_each = local.nodes

  name        = "${var.cluster_name}-${each.key}"
  hostname    = "${var.cluster_name}-${each.key}"
  platform_id = var.platform_id
  folder_id   = local.effective_folder_id
  zone        = var.zone
  labels = merge(local.common_labels, {
    role = each.value.role
  })

  resources {
    cores         = var.cores
    memory        = var.memory_gb
    core_fraction = 100
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = var.disk_size_gb
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id          = local.subnet_id
    nat                = true
    ip_address         = var.use_existing_network ? null : each.value.local_ip
    security_group_ids = local.security_group_ids
  }

  metadata = {
    serial-port-enable = "1"
    user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      ssh_user       = var.ssh_user
      ssh_public_key = local.ssh_public_key
    })
  }

  allow_stopping_for_update = true
}

resource "yandex_lb_target_group" "ingress" {
  count = var.manage_load_balancer ? 1 : 0

  name      = "${var.cluster_name}-ingress"
  folder_id = local.effective_folder_id

  dynamic "target" {
    for_each = yandex_compute_instance.node
    content {
      subnet_id = local.subnet_id
      address   = target.value.network_interface[0].ip_address
    }
  }
}

resource "yandex_lb_network_load_balancer" "ingress" {
  count = var.manage_load_balancer ? 1 : 0

  name      = "${var.cluster_name}-ingress"
  folder_id = local.effective_folder_id
  type      = "external"

  listener {
    name        = "http"
    port        = 80
    target_port = 80
    protocol    = "tcp"

    external_address_spec {
      ip_version = "ipv4"
    }
  }

  listener {
    name        = "https"
    port        = 443
    target_port = 443
    protocol    = "tcp"

    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.ingress[0].id

    healthcheck {
      name                = "http"
      interval            = 5
      timeout             = 2
      healthy_threshold   = 2
      unhealthy_threshold = 3

      tcp_options {
        port = 80
      }
    }
  }
}

resource "yandex_iam_service_account" "backup" {
  count = var.manage_backup_resources ? 1 : 0

  name        = "${var.cluster_name}-backup"
  folder_id   = local.effective_folder_id
  description = "Uploads guestbook PostgreSQL backups to Object Storage"
}

resource "yandex_resourcemanager_folder_iam_member" "backup_editor" {
  count = var.manage_backup_resources ? 1 : 0

  folder_id = local.effective_folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.backup[0].id}"
}

data "yandex_client_config" "current" {}

resource "yandex_iam_service_account_static_access_key" "backup" {
  count = var.manage_backup_resources ? 1 : 0

  service_account_id = yandex_iam_service_account.backup[0].id
  description        = "Static S3 credentials consumed by the backup Kubernetes Secret"
}

resource "yandex_storage_bucket" "backup" {
  count = var.manage_backup_resources ? 1 : 0

  bucket = coalesce(
    var.backup_bucket_name,
    "${var.cluster_name}-backup-${random_id.bucket_suffix.hex}"
  )

  access_key    = yandex_iam_service_account_static_access_key.backup[0].access_key
  secret_key    = yandex_iam_service_account_static_access_key.backup[0].secret_key
  max_size      = 10 * 1024 * 1024 * 1024
  force_destroy = true

  anonymous_access_flags {
    read        = false
    list        = false
    config_read = false
  }

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "expire-old-backups"
    enabled = true

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      days = 7
    }
  }

  depends_on = [yandex_resourcemanager_folder_iam_member.backup_editor]
}

resource "yandex_dns_recordset" "app" {
  count = var.manage_dns_record && var.dns_zone_id != null && var.dns_zone_id != "" && var.app_host != null && var.app_host != "" ? 1 : 0

  zone_id = var.dns_zone_id
  name    = "${trimsuffix(var.app_host, ".")}."
  type    = "A"
  ttl     = 60
  data    = [local.app_public_ip]
}
