#!/bin/bash
kubectl patch deployment ingress-nginx-controller -n ingress-nginx \
  --type=merge \
  -p='{"spec":{"template":{"spec":{"hostNetwork":false,"dnsPolicy":"ClusterFirst"}}}}'

# Delete old redirects if they exist (to prevent duplicates)
iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 30080 2>/dev/null || true
iptables -t nat -D PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 30443 2>/dev/null || true
iptables -t nat -D OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-port 30080 2>/dev/null || true
iptables -t nat -D OUTPUT -p tcp -o lo --dport 443 -j REDIRECT --to-port 30443 2>/dev/null || true

# Add the correct redirects
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 30080
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 30443
iptables -t nat -A OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-port 30080
iptables -t nat -A OUTPUT -p tcp -o lo --dport 443 -j REDIRECT --to-port 30443

# Save iptables
netfilter-persistent save

echo "Restarting NGINX..."
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
sleep 10

echo "Cleaning up CRs..."
kubectl delete certificaterequest --all -A 2>/dev/null || true
kubectl delete certificate --all -A 2>/dev/null || true
kubectl delete challenge --all -A 2>/dev/null || true
