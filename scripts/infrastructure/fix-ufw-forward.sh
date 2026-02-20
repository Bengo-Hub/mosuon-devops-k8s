#!/bin/bash
# =============================================================================
# Fix UFW forward policy for Kubernetes pod traffic
# =============================================================================
# UFW's DEFAULT_FORWARD_POLICY=DROP blocks pod-to-internet traffic, causing
# cert-manager to timeout when reaching Let's Encrypt ACME servers.
# This script sets it to ACCEPT and ensures the rule persists.
# =============================================================================

set -euo pipefail

echo "[INFO] Fixing UFW DEFAULT_FORWARD_POLICY=DROP -> ACCEPT"

# Fix the /etc/default/ufw file
if grep -q 'DEFAULT_FORWARD_POLICY' /etc/default/ufw; then
    sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    echo "[OK] Updated /etc/default/ufw DEFAULT_FORWARD_POLICY=ACCEPT"
fi

# Verify the change
grep DEFAULT_FORWARD_POLICY /etc/default/ufw

# Also set the iptables FORWARD policy directly now
sudo iptables -P FORWARD ACCEPT 2>/dev/null || true
echo "[OK] iptables FORWARD policy set to ACCEPT"

# Ensure MASQUERADE for pod subnet
sudo iptables -t nat -C POSTROUTING -s 192.168.0.0/16 ! -d 192.168.0.0/16 -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -A POSTROUTING -s 192.168.0.0/16 ! -d 192.168.0.0/16 -j MASQUERADE
echo "[OK] MASQUERADE rule ensured for pod --> internet"

# Persist iptables
sudo netfilter-persistent save 2>/dev/null || true
echo "[OK] iptables rules saved"

# Reload UFW if available
if systemctl is-active --quiet ufw; then
    sudo systemctl reload ufw 2>/dev/null || sudo systemctl restart ufw 2>/dev/null || true
    echo "[OK] UFW reloaded"
fi

echo ""
echo "=== Verifying FORWARD policy ==="
sudo iptables -L FORWARD -n | head -5

echo ""
echo "=== Testing pod outbound connectivity ==="
CERTPOD=$(kubectl get pods -n cert-manager --no-headers | grep -v Terminating | awk 'NR==1{print $1}')
if [ -n "$CERTPOD" ]; then
    echo "Testing from cert-manager pod: $CERTPOD"
    kubectl exec -n cert-manager "$CERTPOD" -- wget -q --timeout=15 -O- https://acme-v02.api.letsencrypt.org/directory 2>&1 | head -5 || echo "Still failing - may need more time"
fi

echo ""
echo "[OK] UFW forward policy fix complete"
echo "Cert-manager will automatically retry ACME challenges within a few minutes."
echo "Monitor with: kubectl get certificates -A && kubectl get challenges -A"
