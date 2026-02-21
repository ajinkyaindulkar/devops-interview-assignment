# cost_optimization.tf — Cost Optimization Resources
#
# =============================================================================
# COST ANALYSIS — data/aws_cost_report.json (November 2025)
# =============================================================================
#
# Current total: $47,832/month
#
# TOP COST DRIVERS & PROPOSED FIXES:
#
# 1. S3 — vlt-video-chunks-prod  ($10,350/mo, 45 TB, all STANDARD)
#    Problem : 95% of objects are never accessed after day 30, yet stored at
#              STANDARD pricing ($0.023/GB) indefinitely. Oldest objects are
#              730 days old — still paying full price for cold data.
#    Fix     : Three-tier lifecycle — STANDARD_IA at day 31, GLACIER at day 91,
#              DEEP_ARCHIVE at day 366. Deep Archive costs $0.00099/GB vs $0.023.
#    Saving  : ~$5,500/mo (objects older than 90 days → ~60% of bucket)
#    Risk    : GLACIER/Deep Archive retrievals take minutes to hours and carry
#              retrieval fees. Acceptable because 95% of access is within 30 days;
#              the rare cold retrieval (compliance, investigation) can tolerate latency.
#
# 2. S3 — vlt-logs-prod  ($1,415/mo, 8.2 TB, all STANDARD)
#    Problem : Logs are rarely accessed after 7 days. At 545 days oldest object,
#              the bucket grows unbounded with no expiration policy.
#    Fix     : STANDARD_IA at day 8, GLACIER at day 31, delete at day 180.
#              180-day retention satisfies typical audit/compliance windows.
#    Saving  : ~$850/mo
#    Risk    : Objects deleted at 180 days — ensure this aligns with compliance
#              retention requirements before applying to production.
#
# 3. NAT Gateway data processing  ($1,102/mo, 2,450 GB)
#    Problem : All S3 traffic from EKS nodes (video chunk uploads, model pulls)
#              routes through the NAT Gateway at $0.045/GB processed. A Gateway
#              VPC endpoint for S3 is free and bypasses NAT entirely.
#    Fix     : aws_vpc_endpoint.s3 (Gateway type, no hourly charge, no per-GB charge)
#    Saving  : ~$1,100/mo — full elimination of S3-bound NAT data processing costs
#    Risk    : None. Gateway endpoints are HA, region-scoped, and require no config
#              changes to applications — AWS automatically prefers the endpoint route.
#
# 4. EKS video-processing nodes  ($11,520/mo, c5.4xlarge × 8 at 34% avg utilisation)
#    Problem : On-demand at 34% utilisation = paying for 66% idle capacity. These
#              are batch-style video processing jobs that can be checkpointed and
#              retried on spot interruption.
#    Fix     : Dedicated SPOT node group with multiple instance type fallbacks
#              (c5.2xlarge, c5.4xlarge, c5a.4xlarge, c5n.4xlarge) to maximise
#              spot pool availability. Spot saves 60-70% on EC2 costs.
#    Saving  : ~$5,000-7,000/mo
#    Risk    : Spot interruptions (avg 5% frequency). Jobs must be idempotent and
#              use checkpointing. NOT applied to GPU nodes (61% util, inference
#              latency-sensitive — a spot reclaim mid-inference drops the request).
#
# 5. Additional recommendations (not Terraform-managed in this module):
#    - Consolidate 3 bastion hosts (5% util, $793/mo) → 1 bastion + SSM Session
#      Manager for the others. Saves ~$530/mo with zero security regression.
#    - Downsize PostgreSQL Multi-AZ from db.r5.2xlarge to db.r5.xlarge (28% util).
#      Saves ~$1,200/mo. Evaluate read replica necessity (12% util each).
#    - Review 1,200 CloudWatch custom metrics ($960/mo) — migrate lower-priority
#      metrics to Prometheus/Grafana to avoid CloudWatch per-metric charges.
#
# ESTIMATED TOTAL MONTHLY SAVINGS: $12,000–15,000 (25–31% reduction)
# =============================================================================

# =============================================================================
# S3 LIFECYCLE — VIDEO CHUNKS BUCKET
#
# Access pattern: 95% of reads happen within the first 30 days.
# Beyond day 30, objects are effectively cold (compliance/investigation only).
# Tiering schedule:
#   Day 0–30   : STANDARD       — fast access for active processing & re-uploads
#   Day 31–90  : STANDARD_IA    — infrequent access tier, same durability, 40% cheaper
#   Day 91–365 : GLACIER        — archival, retrieval in minutes, 83% cheaper than STANDARD
#   Day 366+   : DEEP_ARCHIVE   — long-term retention, retrieval in hours, 96% cheaper
# =============================================================================

resource "aws_s3_bucket_lifecycle_configuration" "video_chunks" {
  bucket = var.video_chunks_bucket

  rule {
    id     = "tiered-storage-by-age"
    status = "Enabled"

    transition {
      days          = 31
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 91
      storage_class = "GLACIER"
    }

    transition {
      days          = 366
      storage_class = "DEEP_ARCHIVE"
    }
  }
}

# =============================================================================
# S3 LIFECYCLE — LOGS BUCKET
#
# Access pattern: rarely accessed after 7 days (monitoring dashboards look back
# 7 days max; older data is only pulled for investigations or audits).
# Tiering + expiration schedule:
#   Day 0–7   : STANDARD      — needed for live dashboards and recent debugging
#   Day 8–30  : STANDARD_IA   — occasional access during incident follow-ups
#   Day 31–180: GLACIER        — compliance/audit retrieval only
#   Day 181+  : Delete         — 180-day retention satisfies most audit windows;
#                               adjust before applying if stricter retention required
# =============================================================================

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = var.logs_bucket

  rule {
    id     = "logs-tiering-and-expiry"
    status = "Enabled"

    transition {
      days          = 8
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 31
      storage_class = "GLACIER"
    }

    expiration {
      days = 180
    }
  }
}

# =============================================================================
# S3 GATEWAY VPC ENDPOINT
#
# All S3 traffic from EKS nodes (video uploads, ECR layer pulls, model artifact
# downloads) currently exits through the NAT Gateway at $0.045/GB — costing
# $1,102/mo for 2,450 GB. A Gateway endpoint routes this traffic directly inside
# the AWS network at no charge. AWS automatically adds a route to the specified
# route tables; no application changes are needed.
#
# Only the private route table is included because public subnets already have
# a direct internet path via the IGW and don't route through NAT.
# =============================================================================

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  # Add the endpoint route to private subnets only — nodes and pods live there
  route_table_ids = [aws_route_table.private.id]

  tags = {
    Name = "${var.cluster_name}-s3-endpoint"
  }
}

# =============================================================================
# SPOT NODE GROUP — VIDEO PROCESSING
#
# The video-processing node group runs c5.4xlarge × 8 at 34% average utilisation
# on-demand, costing $11,520/mo. These nodes run stateless, batch-style video
# chunk processing jobs that can be retried on interruption — a suitable spot
# workload profile.
#
# Multiple instance types are listed so EC2 can fall back across a larger spot
# pool, reducing the chance of simultaneous interruptions across the group.
# The "video-processing" label allows the Kubernetes scheduler to target these
# nodes specifically via nodeSelector or nodeAffinity.
#
# GPU nodes are deliberately kept on-demand: inference is latency-sensitive and
# a spot reclaim mid-request drops the inference result with no retry path.
# =============================================================================

resource "aws_eks_node_group" "video_processing_spot" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-video-processing-spot"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  subnet_ids    = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  capacity_type = "SPOT"

  # Multiple compatible instance types maximise the available spot pool.
  # c5.2xlarge provides the same vCPU:memory ratio as c5.4xlarge at half the
  # blast radius per interruption; c5a and c5n variants add AMD/network-optimised
  # fallbacks for the same workload profile.
  instance_types = ["c5.2xlarge", "c5.4xlarge", "c5a.4xlarge", "c5n.4xlarge"]

  scaling_config {
    min_size     = 2
    max_size     = 12
    desired_size = 5
  }

  update_config {
    # Allow two nodes unavailable during updates — spot interruptions already
    # require jobs to tolerate node loss, so this is safe.
    max_unavailable = 2
  }

  labels = {
    "workload-type" = "video-processing"
    "capacity-type" = "spot"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
  ]
}
