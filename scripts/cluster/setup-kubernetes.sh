#!/bin/bash
set -euo pipefail

# kubeadm-based Kubernetes installer (Mosuon)

CLUSTER_NAME=${CLUSTER_NAME:-mosuon-prod}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.30}
POD_NETWORK_CIDR=${POD_NETWORK_CIDR:-192.168.0.0/16}
CALICO_VERSION=${CALICO_VERSION:-3.28.0}
TIGERA_OPERATOR_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/tigera-operator.yaml"
CALICO_CUSTOM_RESOURCES_URL="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/custom-resources.yaml"
CALICO_MANIFEST_RETRY_ATTEMPTS=${CALICO_MANIFEST_RETRY_ATTEMPTS:-5}
CALICO_MANIFEST_RETRY_DELAY=${CALICO_MANIFEST_RETRY_DELAY:-5}
CALICO_INSTALLATION_CRD=${CALICO_INSTALLATION_CRD:-installations.operator.tigera.io}
CALICO_CRD_WAIT_TIMEOUT=${CALICO_CRD_WAIT_TIMEOUT:-120}

apply_manifest_with_retry() {
  local manifest_url=${1:?manifest URL is required}
  local attempt=1
  while :; do
    if kubectl apply -f "$manifest_url"; then
      return 0
    fi
    if [ "$attempt" -ge "$CALICO_MANIFEST_RETRY_ATTEMPTS" ]; then
      echo "❌ Failed to apply ${manifest_url} after ${attempt} attempts" >&2
      return 1
    fi
    echo "Retrying Calico manifest (${attempt}/${CALICO_MANIFEST_RETRY_ATTEMPTS}) in ${CALICO_MANIFEST_RETRY_DELAY}s"
    attempt=$((attempt + 1))
    sleep "$CALICO_MANIFEST_RETRY_DELAY"
  done
}

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo" >&2
  exit 1
fi

if ! systemctl is-active --quiet containerd; then
  echo "containerd not running; run setup-containerd.sh first" >&2
  exit 1
fi

# Add Kubernetes apt repo
if [ ! -f /etc/apt/sources.list.d/kubernetes.list ]; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg || true
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
fi

apt-get update -y
apt-get install -y kubelet kubeadm kubectl || true
apt-mark hold kubelet kubeadm kubectl 2>/dev/null || true
systemctl enable --now kubelet || true

# Initialize cluster if not already
if [ -f /etc/kubernetes/admin.conf ]; then
  echo "Kubernetes already initialized"
else
  APISERVER_ADVERTISE_ADDRESS=$(hostname -I | awk '{print $1}')
  APISERVER_PORT=${APISERVER_PORT:-6444}
  kubeadm init --pod-network-cidr="${POD_NETWORK_CIDR}" --apiserver-advertise-address="${APISERVER_ADVERTISE_ADDRESS}" --apiserver-bind-port="${APISERVER_PORT}" --kubernetes-version="v${KUBERNETES_VERSION}.0" || true
fi

# configure kubectl for root and ubuntu user
mkdir -p $HOME/.kube
if [ -f /etc/kubernetes/admin.conf ] && [ ! -f $HOME/.kube/config ]; then
  cp /etc/kubernetes/admin.conf $HOME/.kube/config || true
  chown $(id -u):$(id -g) $HOME/.kube/config || true
fi
if id "ubuntu" &>/dev/null; then
  mkdir -p /home/ubuntu/.kube
  cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config || true
  chown -R ubuntu:ubuntu /home/ubuntu/.kube || true
fi

# Allow pods on master (single-node)
if kubectl get nodes >/dev/null 2>&1; then
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
fi

# Install Calico CNI (idempotent)
if kubectl get namespace calico-system >/dev/null 2>&1; then
  echo "Calico already installed"
else
  if ! apply_manifest_with_retry "${TIGERA_OPERATOR_MANIFEST_URL}"; then
    echo "❌ Calico operator manifest install failed" >&2
    exit 1
  fi
  sleep 5
  if ! kubectl wait --for=condition=Established "crd/${CALICO_INSTALLATION_CRD}" --timeout="${CALICO_CRD_WAIT_TIMEOUT}s" >/dev/null 2>&1; then
    echo "❌ Installation CRD ${CALICO_INSTALLATION_CRD} failed to establish" >&2
    kubectl get crd "${CALICO_INSTALLATION_CRD}" -o yaml || true
    exit 1
  fi
  if ! apply_manifest_with_retry "${CALICO_CUSTOM_RESOURCES_URL}"; then
    echo "❌ Calico custom-resources install failed" >&2
    exit 1
  fi

  echo "Waiting for Calico pods to become Ready"
  CNI_TIMEOUT=${CNI_TIMEOUT:-300}
  if ! kubectl wait --for=condition=Ready pods -n calico-system --all --timeout=${CNI_TIMEOUT}s >/dev/null 2>&1; then
    echo "⚠️ Calico pods did not reach Ready within ${CNI_TIMEOUT} seconds"
    kubectl get pods -n calico-system
  else
    echo "Calico CNI is ready"
  fi
fi

# Update kubeconfig server address if VPS_IP provided
if [ -n "${VPS_IP:-}" ] && [ -f "$HOME/.kube/config" ]; then
  APISERVER_PORT=${APISERVER_PORT:-6444}
  sed -i "s|server: https://.*:6443|server: https://${VPS_IP}:${APISERVER_PORT}|" $HOME/.kube/config || true
  sed -i "s|server: https://.*:${APISERVER_PORT}|server: https://${VPS_IP}:${APISERVER_PORT}|" $HOME/.kube/config || true
fi

echo "Kubernetes setup complete"
