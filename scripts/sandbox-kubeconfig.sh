#!/usr/bin/env bash
# sandbox-kubeconfig.sh — open a direct kubectl path from the sandbox to an EKS
# cluster API via an SSM port-forward tunnel through the per-cluster relay.
#
# WHY: the sandbox egress gateway (AGENTS §6.27) refuses the EKS API's private-CA
# cert. This tunnels raw TCP over the SSM data channel (whose ssmmessages cert IS
# publicly trusted, so the gateway accepts it), and kubectl does genuine
# end-to-end TLS to the apiserver — verifying the REAL cluster CA. No public
# listener; auth is IAM (ssm:StartSession) + an EKS access entry for this identity.
#
# ONE shared relay (tagged Role=kube-relay) serves every cluster: it lives in
# the base VPC that all clusters share, and each cluster's SG admits it on 443
#   * the relay instance + mgmt SG rule -> terraform/management/kube-access.tf
#   * each platform cluster's SG rule   -> crossplane/compositions/platform-cluster.yaml
# (the account's 9-instance cap rules out a per-cluster relay).
#
# USAGE
#   scripts/sandbox-kubeconfig.sh [-c CLUSTER] [-r REGION] [-p LOCAL_PORT] [--exec CMD ...]
#
#   # one-shot: run a command with the tunnel up, then tear down
#   scripts/sandbox-kubeconfig.sh -c k8-platform-mgmt --exec kubectl get nodes
#
#   # interactive: open the tunnel, print the KUBECONFIG to source, leave it up
#   eval "$(scripts/sandbox-kubeconfig.sh -c k8-platform-mgmt)"
#   kubectl get nodes
#   scripts/sandbox-kubeconfig.sh --stop          # tear the tunnel down
#
# Requires: aws CLI v2, the session-manager-plugin, kubectl, jq.
set -euo pipefail

CLUSTER="${KUBE_RELAY_CLUSTER:-k8-platform-mgmt}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
LOCAL_PORT=""
RUN_DIR="${TMPDIR:-/tmp}/sandbox-kubeconfig"
EXEC_CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--cluster) CLUSTER="$2"; shift 2 ;;
    -r|--region)  REGION="$2";  shift 2 ;;
    -p|--port)    LOCAL_PORT="$2"; shift 2 ;;
    --stop)       STOP=1; shift ;;
    --exec)       shift; EXEC_CMD=("$@"); break ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

state_dir() { echo "${RUN_DIR}/${CLUSTER}"; }

stop_tunnel() {
  local sd; sd="$(state_dir)"
  if [ -f "${sd}/pid" ]; then
    local pid; pid="$(cat "${sd}/pid")"
    if kill "${pid}" 2>/dev/null; then echo "stopped tunnel (pid ${pid}) for ${CLUSTER}" >&2; fi
    rm -f "${sd}/pid"
  else
    echo "no tracked tunnel for ${CLUSTER}" >&2
  fi
}

if [ "${STOP:-0}" = "1" ]; then stop_tunnel; exit 0; fi

for bin in aws kubectl jq session-manager-plugin; do
  command -v "$bin" >/dev/null 2>&1 || { echo "FATAL: '$bin' not found on PATH" >&2; exit 1; }
done

SD="$(state_dir)"; mkdir -p "${SD}"

# Pick a free-ish local port deterministically per cluster if not given.
if [ -z "${LOCAL_PORT}" ]; then
  LOCAL_PORT=$(( 8443 + ( $(echo -n "${CLUSTER}" | cksum | cut -d' ' -f1) % 1000 ) ))
fi

# 1. Discover the shared relay instance (one per account, tagged Role=kube-relay).
RELAY_ID=$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:Role,Values=kube-relay" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[0].InstanceId' --output text | tr -d '[:space:]')
[ -n "${RELAY_ID}" ] && [ "${RELAY_ID}" != "None" ] \
  || { echo "FATAL: no running kube-relay instance found in ${REGION} (tag Role=kube-relay)" >&2; exit 1; }

# 2. Read the real EKS endpoint + CA (these are what kubectl verifies end-to-end).
EP=$(aws eks describe-cluster --region "${REGION}" --name "${CLUSTER}" \
  --query 'cluster.endpoint' --output text)
CA=$(aws eks describe-cluster --region "${REGION}" --name "${CLUSTER}" \
  --query 'cluster.certificateAuthority.data' --output text)
EP_HOST="${EP#https://}"; EP_HOST="${EP_HOST%%/*}"

# 3. Open the SSM port-forward to the EKS endpoint (raw TCP; kubectl TLS rides inside).
nohup aws ssm start-session --region "${REGION}" \
  --target "${RELAY_ID}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${EP_HOST}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}" \
  > "${SD}/tunnel.log" 2>&1 &
echo "$!" > "${SD}/pid"

# Wait for the tunnel to report the port open.
for _ in $(seq 1 30); do
  grep -q "Waiting for connections" "${SD}/tunnel.log" 2>/dev/null && break
  sleep 1
done
grep -q "Waiting for connections" "${SD}/tunnel.log" 2>/dev/null \
  || { echo "FATAL: SSM tunnel did not open. Log:" >&2; cat "${SD}/tunnel.log" >&2; stop_tunnel; exit 1; }

# 4. Write a kubeconfig. server=localhost (the tunnel), but tls-server-name is the
#    real endpoint host so the cluster CA's SAN check passes; token via exec plugin.
KCFG="${SD}/kubeconfig"
cat > "${KCFG}" <<YAML
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER}
  cluster:
    server: https://127.0.0.1:${LOCAL_PORT}
    certificate-authority-data: ${CA}
    tls-server-name: ${EP_HOST}
contexts:
- name: ${CLUSTER}
  context:
    cluster: ${CLUSTER}
    user: ${CLUSTER}
current-context: ${CLUSTER}
users:
- name: ${CLUSTER}
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws
      args: ["eks", "get-token", "--cluster-name", "${CLUSTER}", "--region", "${REGION}"]
YAML

if [ "${#EXEC_CMD[@]}" -gt 0 ]; then
  # one-shot mode: run the command with KUBECONFIG set, then tear down.
  trap 'stop_tunnel' EXIT
  KUBECONFIG="${KCFG}" "${EXEC_CMD[@]}"
else
  # interactive mode: print export lines for `eval`, leave the tunnel running.
  echo "# kube-relay tunnel up for ${CLUSTER} (relay ${RELAY_ID}, localhost:${LOCAL_PORT})" >&2
  echo "# stop it with: scripts/sandbox-kubeconfig.sh -c ${CLUSTER} --stop" >&2
  echo "export KUBECONFIG=${KCFG}"
fi
