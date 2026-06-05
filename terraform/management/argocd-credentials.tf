# ArgoCD admin credential, exposed as a Terraform output so a session can
# DRIVE ArgoCD (sync the platform-cluster XR, query Application sync/health,
# refresh) without standing kube/cluster credentials. The agent has no AWS
# or kubeconfig creds in the sandbox; the supported path is to read these
# outputs (via CI, which holds the state-backend creds) and run the argocd
# CLI. See AGENTS.md §10.1 and §6.22.

resource "random_password" "argocd_admin" {
  length = 24
  # Alphanumeric only — the value is passed through a shell (htpasswd) and an
  # `argocd login --password`, so avoid special chars that would need quoting.
  special = false
}

# Patch the bcrypt hash into argocd-secret in a local-exec. The bcrypt is
# computed IN the provisioner (htpasswd), NOT via Terraform's bcrypt()
# function — bcrypt() re-salts on every plan and would show a perpetual diff.
# triggers_replace on the plaintext means this only re-runs when the password
# actually changes (e.g. a fresh account). The $2y->$2a rewrite is required:
# Go's bcrypt (ArgoCD) accepts $2a/$2b but not htpasswd's $2y prefix.
resource "terraform_data" "argocd_admin_password" {
  triggers_replace = [random_password.argocd_admin.result]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig /tmp/k8-platform-kubeconfig
      export KUBECONFIG=/tmp/k8-platform-kubeconfig
      kubectl wait --for=condition=Available --timeout=300s -n argocd deploy/argocd-server
      if ! command -v htpasswd >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y -qq apache2-utils
      fi
      HASH=$(htpasswd -nbBC 10 "" '${random_password.argocd_admin.result}' | tr -d ':\n' | sed 's/$2y/$2a/')
      MTIME=$(date -u +%FT%TZ)
      kubectl -n argocd patch secret argocd-secret --type merge \
        -p "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$MTIME\"}}"
      # Roll the server so it picks up the new admin password immediately.
      kubectl -n argocd rollout restart deploy/argocd-server
      kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
    EOT
  }

  depends_on = [helm_release.argocd]
}
