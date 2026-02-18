#!/usr/bin/env bash
set -euo pipefail

# Helper to run the Mosuon repo cluster setup on the remote VPS.
# This script SSHs into the VPS, clones/updates the mosuon-devops-k8s repo under /opt and runs setup-cluster.sh.
# Usage: ./run-remote-setup.sh root@207.180.237.35

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <user@vps-ip>" >&2
  exit 1
fi
TARGET="$1"
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

echo "==> Remote setup completed (check SSH output for kubeconfig base64 string)."

echo "Note: this script does NOT set GitHub secrets automatically. Copy the base64 kubeconfig and set the KUBE_CONFIG secret in GitHub."
