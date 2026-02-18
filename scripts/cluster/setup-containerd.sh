#!/bin/bash
set -euo pipefail

# Containerd installer/configurer (Mosuon)

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo" >&2
  exit 1
fi

if command -v containerd &>/dev/null && systemctl is-active --quiet containerd; then
  echo "containerd already installed and running"
  containerd --version || true
  crictl --version 2>/dev/null || true
  exit 0
fi

# Add Docker repo for containerd
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true
chmod a+r /etc/apt/keyrings/docker.gpg || true
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable
EOF

apt-get update -y
apt-get install -y containerd.io

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.9"|' /etc/containerd/config.toml || true

systemctl daemon-reload
systemctl enable --now containerd

# Install crictl
CRICTL_VERSION="v1.30.0"
if ! command -v crictl &>/dev/null; then
  wget -q "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
  tar zxvf "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" -C /usr/local/bin
  rm -f "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
fi

cat > /etc/crictl/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

containerd --version || true
crictl --version || true

echo "containerd setup complete"
