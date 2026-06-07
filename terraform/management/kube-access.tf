# Direct sandbox kubectl access to the management cluster API.
#
# WHY THIS EXISTS
# ---------------
# The Anthropic sandbox egress is a strict-verifying MITM gateway (AGENTS §6.27):
# it terminates TLS and verifies the *upstream* server certificate against public
# roots. The EKS API server always presents a cert signed by the cluster's
# PRIVATE CA, so a direct `kubectl` from the sandbox 503s at the gateway. Giving
# the EKS endpoint a public cert is impossible (AWS owns the managed control-plane
# cert), so we front the API with a mechanism whose upstream cert IS publicly
# trusted: an AWS SSM Session Manager port-forward tunnel.
#
# The sandbox runs `aws ssm start-session ... AWS-StartPortForwardingSessionToRemoteHost`
# against a tiny SSM-registered relay instance in this VPC. The SSM data channel
# is a websocket to `ssmmessages.<region>.amazonaws.com`, which presents a public
# AWS cert (gateway accepts it — validated live, spike 2026-06-07). The relay then
# opens a RAW TCP connection to the EKS API endpoint, so kubectl performs genuine
# end-to-end TLS to the apiserver and verifies the REAL cluster CA — no cert
# substitution, and nothing internet-facing is added.
#
# SECURITY POSTURE
# ----------------
#   * No public listener is created. The relay has NO inbound security-group rule.
#   * Reaching the API is gated by (a) IAM: only principals allowed `ssm:StartSession`
#     on this instance can open the tunnel, and (b) kube RBAC: the sandbox identity
#     gets a read-only EKS access entry (AmazonEKSAdminViewPolicy) below.
#   * The relay reaches the cluster's PRIVATE endpoint via cluster-SG membership,
#     so this path does not depend on public endpoint access at all.
# See docs/decisions/0008-sandbox-kubectl-via-ssm-tunnel.md.

# ──────────────────────────────────────────────────────────────────────────────
# Auth: the sandbox IAM identity already has an EKS access entry on THIS cluster.
# ──────────────────────────────────────────────────────────────────────────────
# The sandbox authenticates with `aws eks get-token`; the cluster must map that
# IAM principal to kube RBAC. On the management cluster the sandbox identity
# (`user/cloud_user`) IS the cluster creator — CI applies this module with
# cloud_user's credentials — so `enable_cluster_creator_admin_permissions = true`
# (eks.tf) already creates an admin access entry for it. We therefore do NOT add
# a second entry here: a duplicate STANDARD entry for the same principal is a
# ResourceInUseException. (Platform clusters are created by the Crossplane role,
# not cloud_user, so their Composition DOES add a read-only access entry —
# AmazonEKSAdminViewPolicy — for the sandbox identity.) The module pins
# authentication_mode = API_AND_CONFIG_MAP so access entries are honored.

# ──────────────────────────────────────────────────────────────────────────────
# The SSM relay instance — ONE shared relay for ALL clusters.
# ──────────────────────────────────────────────────────────────────────────────
# The AWS account is hard-capped at 9 EC2 instances (a #10 closes the account),
# so we do NOT stand up a relay per cluster. Every cluster (the mgmt hub and all
# platform clusters) lives in the SAME base VPC, so a single relay can tunnel to
# any cluster's PRIVATE API endpoint — each cluster's security group just has to
# admit the relay on 443. The mgmt rule is below; platform clusters add the
# equivalent rule in their Composition, reading this relay's SG id from the
# cluster-network EnvironmentConfig (relaySecurityGroupId, see crossplane-phase3.tf).
data "aws_ssm_parameter" "kube_relay_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_iam_role" "kube_relay" {
  name = "${var.cluster_name}-kube-relay"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# AmazonSSMManagedInstanceCore is what lets the instance register with Systems
# Manager and accept Session Manager connections. It grants NO access to the
# kube API — that is purely a network reach (TCP to the private endpoint).
resource "aws_iam_role_policy_attachment" "kube_relay_ssm" {
  role       = aws_iam_role.kube_relay.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "kube_relay" {
  name = "${var.cluster_name}-kube-relay"
  role = aws_iam_role.kube_relay.name
}

# Outbound-only SG. No ingress: SSM is initiated by the agent (outbound 443).
# Egress 443 covers BOTH the SSM endpoints and every cluster's EKS API; 53 = DNS.
# This SG is also the *source* admitted by each cluster's SG (see below + the
# Composition), so it is published to the cluster-network EnvironmentConfig.
resource "aws_security_group" "kube_relay" {
  name_prefix = "${var.cluster_name}-kube-relay-"
  description = "SSM kube-API relay: outbound only (SSM + EKS API + DNS)"
  vpc_id      = local.base_vpc_id

  egress {
    description = "HTTPS to SSM endpoints and the EKS API server"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS (resolve SSM endpoints + the EKS private endpoint FQDN)"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS over TCP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-kube-relay" }
}

resource "aws_instance" "kube_relay" {
  ami           = nonsensitive(data.aws_ssm_parameter.kube_relay_ami.value)
  instance_type = "t3.nano"
  subnet_id     = aws_subnet.management[0].id

  iam_instance_profile = aws_iam_instance_profile.kube_relay.name

  # Just the relay's own outbound-only SG. Reach to each cluster's PRIVATE API
  # endpoint is granted by an ingress rule on THAT cluster's SG admitting this
  # relay SG (kube_relay_to_mgmt below for the hub; the Composition for spokes) —
  # not by SG membership, so one relay serves every cluster.
  vpc_security_group_ids = [aws_security_group.kube_relay.id]

  # IMDSv2 required (no metadata SSRF surface).
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  # The AL2023 AMI id rolls forward in SSM; pinning ignore_changes keeps a fresh
  # AMI release from triggering a relay replacement on unrelated applies.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${var.cluster_name}-kube-relay"
    # Discovery key for scripts/sandbox-kubeconfig.sh. ONE shared relay serves
    # every cluster, so the tag is not cluster-specific.
    Role = "kube-relay"
  }
}

# Admit the relay to the management cluster's PRIVATE API endpoint on 443.
# (Platform clusters add the same rule in their Composition.)
resource "aws_vpc_security_group_ingress_rule" "kube_relay_to_mgmt" {
  security_group_id            = module.eks.cluster_primary_security_group_id
  referenced_security_group_id = aws_security_group.kube_relay.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "SSM kube-API relay to mgmt API server"
}
