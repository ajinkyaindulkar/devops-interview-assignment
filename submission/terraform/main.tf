# main.tf — EKS Cluster and Node Groups

# =============================================================================
# EKS CLUSTER IAM ROLE
# The EKS control plane needs this role so AWS can call EC2, ELB, and other
# APIs on our behalf when managing the cluster (e.g. creating ENIs, attaching
# load balancers). AmazonEKSClusterPolicy grants exactly those permissions.
# =============================================================================

resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# =============================================================================
# EKS CLUSTER
# Placed in private subnets so the node API is not internet-routable.
# Cluster logging enabled for api, audit, and authenticator — this provides an
# audit trail for control-plane calls and auth events, required for
# SOC2/compliance posture and essential for incident investigation.
# =============================================================================

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.eks_cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids      = [aws_security_group.eks_nodes.id]
    endpoint_private_access = true
    # Public endpoint kept enabled for kubectl access from bastion/CI.
    # Set to false in a fully air-gapped environment.
    endpoint_public_access = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# =============================================================================
# NODE GROUP IAM ROLE
# Worker nodes run as EC2 instances, so the trust principal is ec2.amazonaws.com.
# Three managed policies are required:
#   AmazonEKSWorkerNodePolicy        — lets nodes register with the cluster
#   AmazonEKS_CNI_Policy             — lets the VPC CNI plugin assign pod IPs
#   AmazonEC2ContainerRegistryReadOnly — lets nodes pull images from ECR
# =============================================================================

resource "aws_iam_role" "eks_nodes" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# =============================================================================
# GENERAL NODE GROUP
# Handles all non-GPU workloads (stream processors, API servers, dashboards).
# Instance type and sizing are variables so they can be right-sized per
# environment without touching code (dev smaller, prod larger).
# Spread across both private subnets for multi-AZ availability.
# =============================================================================

resource "aws_eks_node_group" "general" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-general"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  # Private subnets only — nodes must never have public IPs
  subnet_ids     = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  instance_types = var.general_node_instance_types

  scaling_config {
    min_size     = var.general_node_min_size
    max_size     = var.general_node_max_size
    desired_size = var.general_node_desired_size
  }

  update_config {
    # Keep one node unavailable maximum during rolling updates to maintain capacity
    max_unavailable = 1
  }

  # depends_on ensures all three IAM policy attachments complete before nodes
  # try to register — without this, nodes can fail auth on first boot.
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
  ]
}

# =============================================================================
# GPU NODE GROUP
# Dedicated to AI inference workloads. g4dn.xlarge provides a T4 GPU, matching
# the edge device hardware (site_spec.json: NVIDIA T4) so models are validated
# on equivalent hardware before cloud deployment.
#
# The NO_SCHEDULE taint (nvidia.com/gpu=true) ensures only pods that explicitly
# tolerate this taint land on GPU nodes — preventing general workloads from
# consuming expensive GPU capacity and starving inference pods of headroom.
# =============================================================================

resource "aws_eks_node_group" "gpu" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-gpu"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  subnet_ids     = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  instance_types = ["g4dn.xlarge"]

  scaling_config {
    min_size     = var.gpu_node_min_size
    max_size     = var.gpu_node_max_size
    desired_size = var.gpu_node_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  taint {
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "workload-type" = "gpu-inference"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
  ]
}
