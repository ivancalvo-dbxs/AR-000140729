# Isolated compute VPC: no internet gateway, no NAT, no public IPs. Clusters reach the control plane
# through back-end PrivateLink and AWS services through VPC endpoints with restrictive policies.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Two cluster subnets of a quarter of the VPC each; two PrivateLink subnets 1/64 of the VPC each.
  compute_subnet_cidrs     = [for i in range(2) : cidrsubnet(var.vpc_cidr, 2, i)]
  privatelink_subnet_cidrs = [for i in range(2) : cidrsubnet(var.vpc_cidr, 6, 32 + i)]

  # Ports Databricks needs from clusters to the control plane endpoints (SRA).
  control_plane_ports = [443, 2443, 5432, 6666, 8443, 8444, 8445, 8446, 8447, 8448, 8449, 8450, 8451]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required by PrivateLink private DNS

  tags = { Name = "${module.names.workspace_name}-vpc" }
}

# No rules: nothing may silently use the default security group.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_subnet" "compute" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.compute_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]
  # Secure cluster connectivity: nodes never get public IPs.
  map_public_ip_on_launch = false

  tags = { Name = "${module.names.workspace_name}-compute-${local.azs[count.index]}" }
}

resource "aws_subnet" "privatelink" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.privatelink_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${module.names.workspace_name}-privatelink-${local.azs[count.index]}" }
}

# Local routes only; the S3 gateway endpoint adds the S3 prefix list route.
resource "aws_route_table" "compute" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${module.names.workspace_name}-compute" }
}

resource "aws_route_table_association" "compute" {
  count = 2

  subnet_id      = aws_subnet.compute[count.index].id
  route_table_id = aws_route_table.compute.id
}

resource "aws_route_table" "privatelink" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${module.names.workspace_name}-privatelink" }
}

resource "aws_route_table_association" "privatelink" {
  count = 2

  subnet_id      = aws_subnet.privatelink[count.index].id
  route_table_id = aws_route_table.privatelink.id
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = var.flow_logs_s3_bucket_arn
}

# ---------------------------------------------------------------------------
# Security groups (SRA layout: one for clusters, one for the endpoints).
# ---------------------------------------------------------------------------

data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${var.aws_region}.s3"
}

resource "aws_security_group" "workspace" {
  name        = "${module.names.workspace_name}-workspace"
  description = "Databricks classic clusters"
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = ["tcp", "udp"]
    content {
      description = "Internode communication"
      from_port   = 0
      to_port     = 65535
      protocol    = ingress.value
      self        = true
    }
  }

  dynamic "egress" {
    for_each = ["tcp", "udp"]
    content {
      description = "Internode communication"
      from_port   = 0
      to_port     = 65535
      protocol    = egress.value
      self        = true
    }
  }

  dynamic "egress" {
    for_each = local.control_plane_ports
    content {
      description = "Control plane and AWS service endpoints inside the VPC"
      from_port   = egress.value
      to_port     = egress.value
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  egress {
    description     = "S3 gateway endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_prefix_list.s3.id]
  }

  tags = { Name = "${module.names.workspace_name}-workspace" }
}

resource "aws_security_group" "privatelink" {
  name        = "${module.names.workspace_name}-privatelink"
  description = "Databricks and AWS interface endpoints"
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = local.control_plane_ports
    content {
      description     = "From Databricks clusters"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [aws_security_group.workspace.id]
    }
  }

  tags = { Name = "${module.names.workspace_name}-privatelink" }
}

# ---------------------------------------------------------------------------
# AWS service endpoints with restrictive policies (exfiltration protection).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "s3_endpoint" {
  statement {
    sid       = "OwnAccountBuckets" # root bucket and UC signal buckets
    actions   = ["s3:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:ResourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "DatabricksReadOnlyBuckets" # runtime artifacts and system tables
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = flatten([for b in local.region.read_buckets : ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"]])
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "DatabricksLogBucket"
    actions   = ["s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${local.region.log_bucket}", "arn:aws:s3:::${local.region.log_bucket}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

data "aws_iam_policy_document" "sts_endpoint" {
  statement {
    actions   = ["sts:AssumeRole", "sts:GetAccessKeyInfo", "sts:GetSessionToken", "sts:DecodeAuthorizationMessage", "sts:TagSession"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    actions   = ["sts:AssumeRole", "sts:GetSessionToken", "sts:TagSession"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.databricks_aws_account_id]
    }
  }
}

data "aws_iam_policy_document" "kinesis_endpoint" {
  statement {
    actions   = ["kinesis:PutRecord", "kinesis:PutRecords", "kinesis:DescribeStream"]
    resources = ["arn:aws:kinesis:${var.aws_region}:${local.databricks_aws_account_id}:stream/*"]
    principals {
      type        = "AWS"
      identifiers = [local.databricks_aws_account_id]
    }
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.compute.id]
  policy            = data.aws_iam_policy_document.s3_endpoint.json

  tags = { Name = "${module.names.workspace_name}-s3" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = {
    sts     = { service = "com.amazonaws.${var.aws_region}.sts", policy = data.aws_iam_policy_document.sts_endpoint.json }
    kinesis = { service = "com.amazonaws.${var.aws_region}.kinesis-streams", policy = data.aws_iam_policy_document.kinesis_endpoint.json }
    rest    = { service = local.region.rest_endpoint_service, policy = null }
    relay   = { service = local.region.relay_endpoint_service, policy = null }
  }

  vpc_id              = aws_vpc.this.id
  service_name        = each.value.service
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.privatelink[*].id
  security_group_ids  = [aws_security_group.privatelink.id]
  private_dns_enabled = true # mandatory, or clusters resolve the control plane to public IPs
  policy              = each.value.policy

  tags = { Name = "${module.names.workspace_name}-${each.key}" }
}
