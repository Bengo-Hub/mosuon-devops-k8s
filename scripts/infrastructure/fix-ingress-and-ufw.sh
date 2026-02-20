#!/bin/bash
set -euo pipefail

echo "=== 1. Restoring hostNetwork on Ingress Controller ==="
kubectl patch deployment ingress-nginx-controller -n ingress-nginx \
  --type=merge \
  -p='{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}}}'

# Delete the NodePort service since we use hostNetwork
kubectl delete service ingress-nginx-controller -n ingress-nginx 2>/dev/null || true

echo "=== 2. Cleaning up old iptables redirects ==="
iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 30080 2>/dev/null || true
iptables -t nat -D PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 30443 2>/dev/null || true
iptables -t nat -D OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-port 30080 2>/dev/null || true
iptables -t nat -D OUTPUT -p tcp -o lo --dport 443 -j REDIRECT --to-port 30443 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true

echo "=== 3. Correcting UFW for Kubernetes (Calico) ==="
# Calico requires UFW to ALLOW forwarded packets
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

echo "=== 4. Enabling UFW Firewall with required open ports ==="
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 6444/tcp
ufw allow 2379:2380/tcp
ufw allow 10250/tcp

# Reload/Enable UFW
ufw --force enable

echo "Restarting NGINX..."
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=90s

echo "=== 5. Forcing new ACME challenge ==="
kubectl delete certificaterequest --all -A 2>/dev/null || true
kubectl delete certificate --all -A 2>/dev/null || true
kubectl delete challenge --all -A 2>/dev/null || true

sleep 10
kubectl get challenges -A

echo "Done!"
