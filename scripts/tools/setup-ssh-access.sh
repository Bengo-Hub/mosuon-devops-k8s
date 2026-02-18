#!/usr/bin/env bash
set -euo pipefail

# setup-ssh-access.sh
# - generates (if missing) an ed25519 keypair at $KEY
# - uploads public key to remote authorized_keys (asks for password if needed)
# - adds host to ~/.ssh/known_hosts and creates SSH config alias

VPS_HOST=${1:-207.180.237.35}
VPS_USER=${2:-root}
KEY=${KEY:-$HOME/.ssh/id_ed25519}
ALIAS=${ALIAS:-mosuon-prod}

mkdir -p "$HOME/.ssh"

if [ ! -f "${KEY}.pub" ]; then
  echo "Public key not found at ${KEY}.pub — generating ed25519 keypair..."
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${USER}@$(hostname)"
  echo "Key generated: $KEY"
fi

PUB=$(cat "${KEY}.pub")

echo "Uploading public key to ${VPS_USER}@${VPS_HOST} (password may be required)..."
if command -v ssh-copy-id >/dev/null 2>&1; then
  ssh-copy-id -i "${KEY}.pub" "${VPS_USER}@${VPS_HOST}"
else
  cat "${KEY}.pub" | ssh "${VPS_USER}@${VPS_HOST}" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
fi

echo "Adding host to known_hosts..."
if command -v ssh-keyscan >/dev/null 2>&1; then
  ssh-keyscan -H "$VPS_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
else
  # fallback: attempt to connect once to add host key
  ssh -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" exit || true
fi

# add SSH config entry if missing
CONFIG="$HOME/.ssh/config"
if ! grep -q "^Host ${ALIAS}\b" "$CONFIG" 2>/dev/null; then
  cat >> "$CONFIG" <<EOF
Host ${ALIAS}
  HostName ${VPS_HOST}
  User ${VPS_USER}
  IdentityFile ${KEY}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ServerAliveInterval 60
  ServerAliveCountMax 3
EOF
  echo "Added SSH config alias '${ALIAS}'"
else
  echo "SSH config already contains alias '${ALIAS}'"
fi

# add to ssh-agent
if command -v ssh-agent >/dev/null 2>&1; then
  eval "$(ssh-agent -s)" 2>/dev/null || true
  ssh-add "$KEY" 2>/dev/null || true
  echo "Added key to ssh-agent (if available)"
fi

echo "Done — test with: ssh ${ALIAS} or ssh ${VPS_USER}@${VPS_HOST}"