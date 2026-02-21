variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
}

variable "site_id" {
  description = "Customer site identifier"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "video-analytics"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "management_cidr" {
  description = <<-EOT
    CIDR block permitted to SSH into the bastion host.
    Must be explicitly set per deployment — no default is provided intentionally
    to prevent accidental open access. Use the corporate VPN range or office egress IP.
    Example: "10.50.1.0/24" (on-prem management subnet from site_spec.json).
  EOT
  type        = string

  validation {
    condition     = var.management_cidr != "0.0.0.0/0"
    error_message = "management_cidr must not be 0.0.0.0/0 — restrict SSH to a known management network."
  }
}

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "general_node_instance_types" {
  description = "EC2 instance types for the general-purpose node group"
  type        = list(string)
  default     = ["m5.xlarge"]
}

variable "general_node_min_size" {
  description = "Minimum number of nodes in the general node group"
  type        = number
  default     = 2
}

variable "general_node_max_size" {
  description = "Maximum number of nodes in the general node group"
  type        = number
  default     = 6
}

variable "general_node_desired_size" {
  description = "Desired number of nodes in the general node group"
  type        = number
  default     = 3
}

variable "gpu_node_min_size" {
  description = "Minimum number of nodes in the GPU inference node group"
  type        = number
  default     = 1
}

variable "gpu_node_max_size" {
  description = "Maximum number of nodes in the GPU inference node group"
  type        = number
  default     = 4
}

variable "gpu_node_desired_size" {
  description = "Desired number of nodes in the GPU inference node group"
  type        = number
  default     = 2
}

variable "video_chunks_bucket" {
  description = "Name of the S3 bucket that stores video chunks uploaded from edge devices"
  type        = string
  default     = "vlt-video-chunks-prod"
}

variable "logs_bucket" {
  description = "Name of the S3 bucket that stores application and infrastructure logs"
  type        = string
  default     = "vlt-logs-prod"
}
