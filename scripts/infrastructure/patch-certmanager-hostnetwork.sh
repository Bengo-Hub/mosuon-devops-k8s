#!/bin/bash
# Patch cert-manager to use hostNetwork so ACME API calls go through host network
# This fixes: i/o timeout to letsencrypt.org from cert-manager pods

set -euo pipefail

echo "=== Patching cert-manager to use hostNetwork ==="
kubectl patch deployment cert-manager -n cert-manager \
    --type=merge \
    -p='{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}}}' \
    && echo "[OK] cert-manager hostNetwork=true"

kubectl rollout restart deployment cert-manager -n cert-manager
echo "[OK] cert-manager restarted"

echo "=== Waiting for cert-manager to be ready... ==="
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=90s

echo ""
echo "=== Testing ACME connectivity from cert-manager pod ==="
sleep 15
CERTPOD=$(kubectl get pods -n cert-manager --no-headers | awk '/cert-manager-[a-z0-9]/{print $1; exit}')
echo "Pod: $CERTPOD"
echo "Pod IP (should be 207.180.237.35 with hostNetwork):"
kubectl get pod -n cert-manager "$CERTPOD" -o jsonpath='{.status.podIP}' && echo ""

echo ""
echo "=== Waiting 30s for ACME registration attempt ==="
sleep 30

echo "=== cert-manager logs ==="
kubectl logs -n cert-manager "$CERTPOD" --since=30s 2>&1 | grep -v '^I' | tail -10

echo ""
echo "=== Certificates ==="
kubectl get certificates -A

echo ""
echo "=== CertificateRequests ==="
kubectl get certificaterequests -A 2>/dev/null

echo ""
echo "=== Challenges ==="
kubectl get challenges -A 2>/dev/null || echo "none"
