#!/bin/bash
set -euo pipefail

# Initial VPS Setup Script (Mosuon)
# Prepares Ubuntu 24.04 LTS VPS for Kubernetes cluster installation

CLUSTER_NAME=${CLUSTER_NAME:-mosuon-prod}

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo" >&2
  exit 1
fi

. /etc/os-release || true
if [ -f /etc/os-release ]; then
  if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
    echo "Warning: script is designed for Ubuntu 24.04 LTS (detected $ID $VERSION_ID)"
    read -p "Continue anyway? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      exit 1
    fi
  fi
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

REQUIRED_PACKAGES="curl wget git vim htop ca-certificates gnupg lsb-release software-properties-common apt-transport-https jq net-tools iproute2 iptables conntrack"
PACKAGES_TO_INSTALL=""
for pkg in $REQUIRED_PACKAGES; do
  if ! dpkg -l | grep -q "^ii  $pkg "; then
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL $pkg"
  fi
done
if [ -n "$PACKAGES_TO_INSTALL" ]; then
  apt-get install -y $PACKAGES_TO_INSTALL
fi
apt-get upgrade -y

# Disable swap
if grep -q " swap " /etc/fstab; then
  sed -i '/ swap / s/^/#/' /etc/fstab || true
fi
swapon --show | grep -q . && swapoff -a || true

# Kernel modules
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true

# Sysctl
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system || true

# Timezone
timedatectl set-timezone UTC || true

# Hostname
EXPECTED_HOSTNAME="${CLUSTER_NAME}-master"
if [ "$(hostname)" != "$EXPECTED_HOSTNAME" ]; then
  hostnamectl set-hostname "$EXPECTED_HOSTNAME" || true
  echo "127.0.0.1 $EXPECTED_HOSTNAME" >> /etc/hosts || true
fi

# UFW rules (idempotent)
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable || true
  ufw default deny incoming || true
  ufw default allow outgoing || true
  ufw allow 22/tcp || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw allow 6443/tcp || true
  ufw allow 2379:2380/tcp || true
  ufw allow 10250/tcp || true
  ufw --force enable || true
fi

mkdir -p /opt/deployment-tools
chmod 755 /opt/deployment-tools || true

echo "VPS initial setup complete"
