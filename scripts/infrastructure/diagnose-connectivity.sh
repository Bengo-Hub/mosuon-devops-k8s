#!/bin/bash
# Connectivity test script for diagnosing cert-manager ACME connectivity
set -euo pipefail

echo "=== Finding cert-manager pod ==="
CERTPOD=$(kubectl get pods -n cert-manager --no-headers | awk '/cert-manager-[a-z0-9]/{print $1; exit}')
echo "Pod: $CERTPOD"

echo ""
echo "=== Testing TCP/443 to LetsEncrypt from pod ==="
kubectl exec -n cert-manager "$CERTPOD" -- sh -c 'nc -z -v -w 8 172.65.46.172 443 2>&1; echo "nc exit:$?"' 2>&1 || true

echo ""
echo "=== Testing TCP/80 to public DNS from pod ==="
kubectl exec -n cert-manager "$CERTPOD" -- sh -c 'nc -z -v -w 8 8.8.8.8 53 2>&1; echo "nc exit:$?"' 2>&1 || true

echo ""
echo "=== Test wget from pod (should show LetsEncrypt JSON) ==="
kubectl exec -n cert-manager "$CERTPOD" -- sh -c 'wget -q --timeout=10 -O- https://acme-staging-v02.api.letsencrypt.org/directory 2>&1 | head -5' 2>&1 || echo "wget failed"

echo ""
echo "=== iptables nat POSTROUTING ==="
sudo iptables -t nat -L POSTROUTING -n --line-numbers | head -20

echo ""
echo "=== iptables FORWARD chain ==="
sudo iptables -L FORWARD -n | head -10

echo ""
echo "=== UFW status ==="
cat /etc/default/ufw | grep -E '(FORWARD|INPUT|OUTPUT)' 2>/dev/null

echo ""
echo "=== Certificates ==="
kubectl get certificates -A

echo ""
echo "=== CertificateRequests ==="
kubectl get certificaterequests -A 2>/dev/null

echo ""
echo "=== Active Challenges ==="
kubectl get challenges -A 2>/dev/null || echo "none"

echo ""
echo "=== cert-manager last 25 log lines ==="
kubectl logs deploy/cert-manager -n cert-manager --tail=25 2>&1
