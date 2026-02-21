# outputs.tf — Values exposed to downstream consumers (CI/CD, other modules, operators)
#
# Outputs serve two purposes:
#   1. Cross-module references — other Terraform root modules can consume these
#      via terraform_remote_state without duplicating resource lookups.
#   2. Operator convenience — printed after every apply so engineers can
#      immediately use the values without digging through the state file.

output "vpc_id" {
  description = "ID of the VPC — used by other modules that need to attach resources to this VPC"
  value       = aws_vpc.main.id
}

output "eks_cluster_name" {
  description = "EKS cluster name — used by kubectl, Helm, and CI/CD pipelines"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster API server endpoint — used by kubectl and the AWS auth configmap"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_certificate_authority" {
  description = "Base64-encoded CA certificate for the EKS cluster — required to configure kubectl"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "private_subnet_ids" {
  description = "IDs of the private subnets — used for EKS nodes, RDS, and any resource that must not be internet-reachable"
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "public_subnet_ids" {
  description = "IDs of the public subnets — used for internet-facing load balancers"
  value       = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

output "nat_gateway_ip" {
  description = "Public IP of the NAT Gateway — add this to allowlists on external services (ECR, S3 VPC endpoint fallback) that restrict by source IP"
  value       = aws_eip.nat.public_ip
}

output "eks_node_role_arn" {
  description = "ARN of the EKS node IAM role — referenced when adding aws-auth configmap entries for additional node groups"
  value       = aws_iam_role.eks_nodes.arn
}
