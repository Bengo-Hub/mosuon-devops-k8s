#!/usr/bin/env bash
set -euo pipefail

# push-devENV-to-gh-secrets.sh
# Reads KubeSecrets/devENV.yml and sets a mapped set of GitHub repo secrets via the gh CLI.
# Usage: ./push-devENV-to-gh-secrets.sh [<repo>]

REPO=${1:-Bengo-Hub/mosuon-devops-k8s}
DEVENV=KubeSecrets/devENV.yml

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found in PATH" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "gh CLI not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi
if [ ! -f "$DEVENV" ]; then
  echo "$DEVENV not found" >&2
  exit 1
fi

# Helper to extract literal YAML value (data: keys are base64-encoded)
get_val() {
  key="$1"
  awk -v k="$key" '$0 ~ k":" { sub(/^[ \t]*/,"",$0); sub(/.*:[ \t]*/,"",$0); print; exit }' "$DEVENV" | sed -E 's/^"(.*)"$/\1/'
}

# Map values
KUBECONFIG_B64=$(get_val KUBECONFIG_B64 || true)
SSH_PRIVATE_KEY_B64=$(get_val SSH_PRIVATE_KEY_B64 || true)
VPS_IP_B64=$(get_val VPS_IP || true)
CLIENT_ID_B64=$(get_val CLIENT_ID || true)
CLIENT_SECRET_B64=$(get_val CLIENT_SECRET || true)
API_USERNAME_B64=$(get_val API_USERNAME || true)
VPS_PASSWORD_B64=$(get_val VPS_PASSWORD || true)
ACCOUNT_ID_B64=$(get_val ACCOUNT_ID || true)

# Set KUBE_CONFIG (store base64 string as-is)
if [ -n "$KUBECONFIG_B64" ]; then
  echo -n "$KUBECONFIG_B64" | gh secret set KUBE_CONFIG --repo "$REPO" --body -
  echo "Set KUBE_CONFIG"
fi

# SSH_PRIVATE_KEY
if [ -n "$SSH_PRIVATE_KEY_B64" ]; then
  echo "$SSH_PRIVATE_KEY_B64" | base64 -d | gh secret set SSH_PRIVATE_KEY --repo "$REPO" --body -
  echo "Set SSH_PRIVATE_KEY (from devENV)"
else
  # fallback: if local key exists, use it
  if [ -f "$HOME/.ssh/id_ed25519" ]; then
    cat "$HOME/.ssh/id_ed25519" | gh secret set SSH_PRIVATE_KEY --repo "$REPO" --body -
    echo "Set SSH_PRIVATE_KEY (from local id_ed25519)"
  else
    echo "SSH_PRIVATE_KEY not set (no SSH_PRIVATE_KEY_B64 in devENV.yml and no local key)" >&2
  fi
fi

# SSH_HOST (from VPS_IP)
if [ -n "$VPS_IP_B64" ]; then
  # devENV stores VPS_IP base64; try to decode, else use literal
  if echo "$VPS_IP_B64" | grep -Eq '^[A-Za-z0-9+/=]+$'; then
    VPS_IP=$(echo -n "$VPS_IP_B64" | base64 -d)
  else
    VPS_IP="$VPS_IP_B64"
  fi
  echo -n "$VPS_IP" | gh secret set SSH_HOST --repo "$REPO" --body -
  echo "Set SSH_HOST=$VPS_IP"
fi

# Generic other values (decode base64 if appropriate) and set with same key name
set_from_b64_if_present() {
  k="$1"
  v_b64=$(get_val "$k" || true)
  if [ -n "$v_b64" ]; then
    # decode if base64-like
    if echo "$v_b64" | grep -Eq '^[A-Za-z0-9+/=]+$'; then
      echo -n "$v_b64" | base64 -d | gh secret set "$k" --repo "$REPO" --body -
    else
      echo -n "$v_b64" | gh secret set "$k" --repo "$REPO" --body -
    fi
    echo "Set $k"
  fi
}

set_from_b64_if_present CLIENT_ID
set_from_b64_if_present CLIENT_SECRET
set_from_b64_if_present API_USERNAME
set_from_b64_if_present VPS_PASSWORD
set_from_b64_if_present ACCOUNT_ID

echo "Done. Verify secrets at: https://github.com/$REPO/settings/secrets/actions"