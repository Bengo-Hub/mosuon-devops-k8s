#!/usr/bin/env bash
set -euo pipefail

# Helper to run the Mosuon repo cluster setup on the remote VPS.
# This script SSHs into the VPS, clones/updates the mosuon-devops-k8s repo under /opt and runs setup-cluster.sh.
# Usage: ./run-remote-setup.sh root@207.180.237.35
# Optional second argument: --push-secret  => push base64 kubeconfig to GitHub Actions secret (requires gh auth)
PUSH_GITHUB_SECRET=false
if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  echo "Usage: $0 <user@vps-ip> [--push-secret]" >&2
  echo "  --push-secret  : (optional) push base64 kubeconfig to GitHub secret KUBE_CONFIG using 'gh'" >&2
  exit 1
fi
TARGET="$1"
if [[ "${2:-}" == "--push-secret" ]]; then
  PUSH_GITHUB_SECRET=true
fi
REPO="https://github.com/Bengo-Hub/mosuon-devops-k8s.git"
REMOTE_DIR="/opt/mosuon-devops-k8s"

echo "==> Running remote cluster setup on $TARGET"
ssh "$TARGET" bash -s <<'SSHEOF'
set -euo pipefail
TARGET_DIR="/opt/mosuon-devops-k8s"
if [ -d "$TARGET_DIR" ]; then
  cd "$TARGET_DIR"
  git fetch --all --prune
  # Determine remote default branch (works with 'master' or 'main')
  REMOTE_DEFAULT_BRANCH=$(git remote show origin | sed -n 's/.*HEAD branch: //p' || true)
  if [ -n "$REMOTE_DEFAULT_BRANCH" ]; then
    git reset --hard "origin/${REMOTE_DEFAULT_BRANCH}" || git reset --hard origin/main || git reset --hard origin/master || true
  else
    git reset --hard origin/main || git reset --hard origin/master || true
  fi
else
  git clone https://github.com/Bengo-Hub/mosuon-devops-k8s.git "$TARGET_DIR"
  cd "$TARGET_DIR"
fi
chmod +x scripts/cluster/*.sh
# Run the orchestrator (this performs VPS setup, containerd, kubeadm init, CNI)
./scripts/cluster/setup-cluster.sh
# After completion, print path to kubeconfig; support both k3s and kubeadm locations
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
  echo "Kubeconfig available at /etc/rancher/k3s/k3s.yaml"
  echo "Base64 encoded (single line):"
  sudo cat /etc/rancher/k3s/k3s.yaml | base64 -w 0 || sudo cat /etc/rancher/k3s/k3s.yaml | base64 | tr -d '\n'
elif [ -f /etc/kubernetes/admin.conf ]; then
  echo "Kubeconfig available at /etc/kubernetes/admin.conf"
  echo "Base64 encoded (single line):"
  sudo cat /etc/kubernetes/admin.conf | base64 -w 0 || sudo cat /etc/kubernetes/admin.conf | base64 | tr -d '\n'
else
  echo "Warning: kubeconfig not found in common locations (/etc/rancher/k3s/k3s.yaml or /etc/kubernetes/admin.conf). Check setup logs on the VPS." >&2
fi
SSHEOF

# Capture kubeconfig base64 directly (safer/reliable)
KUBE_B64=$(ssh "$TARGET" 'if [ -f /etc/rancher/k3s/k3s.yaml ]; then sudo cat /etc/rancher/k3s/k3s.yaml | base64 -w0; elif [ -f /etc/kubernetes/admin.conf ]; then sudo cat /etc/kubernetes/admin.conf | base64 -w0; else echo ""; fi') || true

if [[ -z "${KUBE_B64// /}" ]]; then
  echo "Warning: kubeconfig not found on remote. Check run logs on the VPS." >&2
  exit 1
fi

echo "==> Remote setup completed. Retrieved kubeconfig (base64, ${#KUBE_B64} bytes)"

if [[ "$PUSH_GITHUB_SECRET" == "true" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI not installed locally; cannot push secret" >&2
    echo "Copy the kubeconfig and run: gh secret set KUBE_CONFIG --body '<kube-b64>' --repo Bengo-Hub/mosuon-devops-k8s" >&2
    exit 1
  fi
  # Ensure gh is authenticated
  if ! gh auth status >/dev/null 2>&1; then
    echo "gh CLI not authenticated. Run 'gh auth login' before using --push-secret" >&2
    exit 1
  fi
  echo "Pushing KUBE_CONFIG to GitHub repo Bengo-Hub/mosuon-devops-k8s..."
  echo "$KUBE_B64" | gh secret set KUBE_CONFIG --body - --repo Bengo-Hub/mosuon-devops-k8s && echo "✅ KUBE_CONFIG secret updated"
else
  echo "Copy the following value and add it to GitHub secret 'KUBE_CONFIG' in repo Bengo-Hub/mosuon-devops-k8s:" 
  echo "$KUBE_B64"
fi
