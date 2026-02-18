#!/bin/bash
set -euo pipefail

# Complete Kubernetes Cluster Setup Orchestrator (Mosuon)
# Orchestrates VPS prep → containerd → kubeadm init → CNI

CLUSTER_NAME=${CLUSTER_NAME:-mosuon-prod}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.30}
SKIP_VPS_SETUP=${SKIP_VPS_SETUP:-false}
SKIP_CONTAINERD=${SKIP_CONTAINERD:-false}
SKIP_KUBERNETES=${SKIP_KUBERNETES:-false}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo "  MOSUON KUBERNETES CLUSTER ORCHESTRATOR"
echo "========================================"

echo "Cluster: ${CLUSTER_NAME}"
echo "Kubernetes: ${KUBERNETES_VERSION}"

echo "\n-- prerequisites: run as root or with sudo --\n"
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo" >&2
  exit 1
fi

# Step 1: VPS setup
if [ "$SKIP_VPS_SETUP" != "true" ]; then
  if [ -f "${SCRIPT_DIR}/setup-vps.sh" ]; then
    bash "${SCRIPT_DIR}/setup-vps.sh"
  else
    echo "setup-vps.sh not found in ${SCRIPT_DIR}" >&2
    exit 1
  fi
else
  echo "Skipping VPS setup (SKIP_VPS_SETUP=true)"
fi

# Step 2: containerd
if [ "$SKIP_CONTAINERD" != "true" ]; then
  if [ -f "${SCRIPT_DIR}/setup-containerd.sh" ]; then
    bash "${SCRIPT_DIR}/setup-containerd.sh"
  else
    echo "setup-containerd.sh not found in ${SCRIPT_DIR}" >&2
    exit 1
  fi
else
  echo "Skipping containerd setup (SKIP_CONTAINERD=true)"
fi

# Step 3: Kubernetes kubeadm
if [ "$SKIP_KUBERNETES" != "true" ]; then
  if [ -f "${SCRIPT_DIR}/setup-kubernetes.sh" ]; then
    bash "${SCRIPT_DIR}/setup-kubernetes.sh"
  else
    echo "setup-kubernetes.sh not found in ${SCRIPT_DIR}" >&2
    exit 1
  fi
else
  echo "Skipping Kubernetes setup (SKIP_KUBERNETES=true)"
fi

# Step 4: etcd auto-compaction (idempotent)
if kubectl get nodes >/dev/null 2>&1; then
  if [ -f /etc/kubernetes/manifests/etcd.yaml ]; then
    if ! grep -q "auto-compaction-mode" /etc/kubernetes/manifests/etcd.yaml; then
      sed -i '/- etcd/a\    - --auto-compaction-mode=revision\n    - --auto-compaction-retention=1000\n    - --quota-backend-bytes=8589934592' /etc/kubernetes/manifests/etcd.yaml || true
      echo "Configured etcd auto-compaction (if present)"
    else
      echo "etcd auto-compaction already configured"
    fi
  else
    echo "etcd manifest not found; skipping etcd tuning"
  fi
else
  echo "Kubernetes not reachable; skipping etcd tuning"
fi

# Final: verify kubeconfig and print base64 for GitHub secret
if [ -f "/etc/kubernetes/admin.conf" ]; then
  mkdir -p "$HOME/.kube"
  cp /etc/kubernetes/admin.conf "$HOME/.kube/config" || true
  chmod 600 "$HOME/.kube/config" || true
  export KUBECONFIG="$HOME/.kube/config"

  if kubectl cluster-info >/dev/null 2>&1; then
    kubectl get nodes || true
    echo "\nBase64-encoded kubeconfig (paste into GitHub secret KUBE_CONFIG):"
    cat "$HOME/.kube/config" | base64 -w 0 2>/dev/null || cat "$HOME/.kube/config" | base64 | tr -d '\n'
  else
    echo "Cluster initialized but kubectl cannot connect yet; check kubelet status"
  fi
else
  echo "admin.conf not found; cluster may not be initialized"
  exit 1
fi
