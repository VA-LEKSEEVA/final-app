variable "cloud_id" {
  description = "Yandex Cloud ID. If omitted, the provider uses the yc CLI profile."
  type        = string
  default     = null
  nullable    = true
}

variable "folder_id" {
  description = "Yandex Cloud folder ID. If omitted, the provider uses the yc CLI profile."
  type        = string
  default     = null
  nullable    = true
}

variable "zone" {
  description = "Availability zone for all three VMs."
  type        = string
  default     = "ru-central1-a"
}

variable "app_host" {
  description = "Real application hostname. Passed by Make as TF_VAR_app_host."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.app_host == null || can(regex(
      "^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$",
      var.app_host
    ))
    error_message = "app_host must be a valid fully-qualified hostname."
  }
}

variable "dns_zone_id" {
  description = "Optional existing Yandex Cloud DNS public zone ID. When set, Terraform creates the APP_HOST A record."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.dns_zone_id == null || (
      can(regex("^dns[a-z0-9]+$", var.dns_zone_id)) &&
      length(var.dns_zone_id) >= 8
    )
    error_message = "dns_zone_id must be a real Yandex Cloud DNS zone ID starting with dns."
  }
}

variable "admin_cidrs" {
  description = "CIDRs allowed to SSH and reach the Kubernetes API. Restrict to your public /32 for production."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for cidr in var.admin_cidrs : can(cidrhost(cidr, 0))])
    error_message = "admin_cidrs must contain at least one valid CIDR."
  }
}

variable "network_name" {
  description = "Name of the VPC network."
  type        = string
  default     = "final-k3s"
}

variable "subnet_cidr" {
  description = "IPv4 CIDR for the cluster subnet."
  type        = string
  default     = "10.20.0.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 10))
    error_message = "subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "cluster_name" {
  description = "Prefix used for VM names and labels."
  type        = string
  default     = "final-k3s"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,40}$", var.cluster_name))
    error_message = "cluster_name must contain lowercase letters, digits, and hyphens."
  }
}

variable "ssh_user" {
  description = "Linux user provisioned by cloud-init."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key added to each VM."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Path used by generated Ansible inventory."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "platform_id" {
  description = "Yandex Compute platform ID."
  type        = string
  default     = "standard-v3"
}

variable "cores" {
  description = "vCPU count per node."
  type        = number
  default     = 2

  validation {
    condition     = var.cores >= 2
    error_message = "Each k3s node needs at least 2 vCPUs."
  }
}

variable "memory_gb" {
  description = "RAM per node in GiB."
  type        = number
  default     = 4

  validation {
    condition     = var.memory_gb >= 4
    error_message = "Each node needs at least 4 GiB RAM for the requested stack."
  }
}

variable "disk_size_gb" {
  description = "Boot disk size per node."
  type        = number
  default     = 40

  validation {
    condition     = var.disk_size_gb >= 30
    error_message = "disk_size_gb must be at least 30 GiB."
  }
}

variable "ubuntu_image_family" {
  description = "Yandex Compute image family."
  type        = string
  default     = "ubuntu-2204-lts"
}

variable "backup_bucket_name" {
  description = "Globally unique Object Storage bucket. Leave null to derive a unique name."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.backup_bucket_name == null || can(regex(
      "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$",
      var.backup_bucket_name
    ))
    error_message = "backup_bucket_name must be a valid S3 bucket name."
  }
}

variable "backup_namespace" {
  description = "Kubernetes namespace that receives the backup Secret."
  type        = string
  default     = "guestbook"
}

variable "backup_secret_name" {
  description = "Kubernetes Secret name expected by the backup CronJob."
  type        = string
  default     = "guestbook-backup"
}

variable "backup_cronjob_name" {
  description = "CronJob used by make backup-check."
  type        = string
  default     = "guestbook-backup"
}

variable "labels" {
  description = "Additional labels applied to cloud resources."
  type        = map(string)
  default     = {}
}
