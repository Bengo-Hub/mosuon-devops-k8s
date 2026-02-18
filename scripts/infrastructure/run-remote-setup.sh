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
  git reset --hard origin/main
else
  git clone https://github.com/Bengo-Hub/mosuon-devops-k8s.git "$TARGET_DIR"
  cd "$TARGET_DIR"
fi
chmod +x scripts/cluster/*.sh
# Run the orchestrator (this performs VPS setup, containerd, kubeadm init, CNI)
./scripts/cluster/setup-cluster.sh
# After completion, print path to kubeconfig
if [ -f /etc/kubernetes/admin.conf ]; then
  echo "Kubeconfig available at /etc/kubernetes/admin.conf"
  echo "Base64 encoded (single line):" 
  sudo cat /etc/kubernetes/admin.conf | base64 -w 0 || sudo cat /etc/kubernetes/admin.conf | base64 | tr -d '\n'
else
  echo "Warning: admin.conf not found after setup. Check kubeadm logs on the VPS." >&2
fi
SSHEOF

echo "==> Remote setup completed (check SSH output for kubeconfig base64 string)."

echo "Note: this script does NOT set GitHub secrets automatically. Copy the base64 kubeconfig and set the KUBE_CONFIG secret in GitHub."
