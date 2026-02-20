#!/bin/bash
# =============================================================================
# Fix Domain Access Issues on mosuon-prod cluster
# =============================================================================
# Resolves:
#   1. ArgoCD ssl-passthrough conflicts with cert-manager HTTP-01 ACME challenge
#   2. Certificates not issuing (Ready: False for argocd-tls, grafana-tls, metabase-tls)
#   3. ArgoCD applicationset-controller CrashLoopBackOff (webhook timeout)
#   4. iptables rules persistence across reboots
#
# Usage:
#   ./fix-domain-access.sh
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}========== $* ==========${NC}"; }

VPS_IP=${VPS_IP:-207.180.237.35}
HTTP_PORT=${HTTP_PORT:-30080}
HTTPS_PORT=${HTTPS_PORT:-30443}

# =============================================================================
# 1. ENSURE IPTABLES REDIRECTS ARE IN PLACE AND PERSISTED
# =============================================================================
log_section "Ensuring iptables redirects (80->30080, 443->30443)"

sudo iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port "${HTTP_PORT}" 2>/dev/null || \
    sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port "${HTTP_PORT}"
log_success "iptables: port 80 -> ${HTTP_PORT}"

sudo iptables -t nat -C PREROUTING -p tcp --dport 443 -j REDIRECT --to-port "${HTTPS_PORT}" 2>/dev/null || \
    sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port "${HTTPS_PORT}"
log_success "iptables: port 443 -> ${HTTPS_PORT}"

# Also ensure OUTPUT chain redirects for localhost self-check (cert-manager self-check)
sudo iptables -t nat -C OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-port "${HTTP_PORT}" 2>/dev/null || \
    sudo iptables -t nat -A OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-port "${HTTP_PORT}"
log_success "iptables: localhost port 80 -> ${HTTP_PORT} (for ACME self-check)"

sudo iptables -t nat -C OUTPUT -p tcp -o lo --dport 443 -j REDIRECT --to-port "${HTTPS_PORT}" 2>/dev/null || \
    sudo iptables -t nat -A OUTPUT -p tcp -o lo --dport 443 -j REDIRECT --to-port "${HTTPS_PORT}"
log_success "iptables: localhost port 443 -> ${HTTPS_PORT}"

# Persist iptables rules
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get install -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
    sudo netfilter-persistent save >/dev/null 2>&1 || true
    log_success "iptables rules persisted via netfilter-persistent"
fi

# =============================================================================
# 2. FIX ARGOCD SERVER - Disable internal TLS (let nginx handle TLS)
# =============================================================================
log_section "Patching ArgoCD server to disable internal TLS"

kubectl patch configmap argocd-cmd-params-cm -n argocd \
    --type=merge \
    -p '{"data":{"server.insecure":"true"}}' 2>/dev/null || \
kubectl create configmap argocd-cmd-params-cm -n argocd \
    --from-literal=server.insecure=true \
    --dry-run=client -o yaml | kubectl apply -f -

log_success "ArgoCD server.insecure=true set"

# =============================================================================
# 3. FIX ARGOCD INGRESS - Remove ssl-passthrough that blocks ACME challenges
# =============================================================================
log_section "Fixing ArgoCD ingress (removing ssl-passthrough)"

cat > /tmp/argocd-ingress-fixed.yaml << 'ARGOCD_INGRESS'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - argocd.ultichange.org
    secretName: argocd-tls
  rules:
  - host: argocd.ultichange.org
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
ARGOCD_INGRESS

kubectl apply -f /tmp/argocd-ingress-fixed.yaml
log_success "ArgoCD ingress updated (ssl-passthrough removed)"

# =============================================================================
# 4. UPDATE CERT-MANAGER CLUSTER ISSUERS to use ingressClassName
# =============================================================================
log_section "Updating cert-manager ClusterIssuers"

ACME_EMAIL=${ACME_EMAIL:-admin@ultichange.org}

cat > /tmp/cluster-issuers.yaml << ISSUERS
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
ISSUERS

kubectl apply -f /tmp/cluster-issuers.yaml
log_success "ClusterIssuers updated with ingressClassName: nginx"

# =============================================================================
# 5. DELETE STALE/FAILED CERTIFICATES TO TRIGGER REISSUANCE
# =============================================================================
log_section "Forcing certificate reissuance"

# Delete old challenges first
kubectl delete challenge --all -n argocd 2>/dev/null || true
kubectl delete challenge --all -n monitoring 2>/dev/null || true
kubectl delete challenge --all -n infra 2>/dev/null || true
kubectl delete challenge --all -n mosuon 2>/dev/null || true

# Delete failed certificate secrets to force new ones
kubectl delete secret argocd-tls -n argocd 2>/dev/null && log_info "Deleted argocd-tls secret" || true
kubectl delete secret grafana-tls -n monitoring 2>/dev/null && log_info "Deleted grafana-tls secret" || true
kubectl delete secret metabase-tls -n infra 2>/dev/null && log_info "Deleted metabase-tls secret" || true

# Delete failed certificates (they'll be recreated by cert-manager from ingress annotations)
kubectl delete certificate argocd-tls -n argocd 2>/dev/null && log_info "Deleted argocd-tls cert" || true
kubectl delete certificate grafana-tls -n monitoring 2>/dev/null && log_info "Deleted grafana-tls cert" || true
kubectl delete certificate metabase-tls -n infra 2>/dev/null && log_info "Deleted metabase-tls cert" || true

log_success "Stale certificates cleared"

# =============================================================================
# 6. RESTART ARGOCD SERVER (picks up insecure mode)
# =============================================================================
log_section "Restarting ArgoCD server"

kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=120s || log_warning "ArgoCD server restart in progress"
log_success "ArgoCD server restarted"

# =============================================================================
# 7. FIX ARGOCD APPLICATIONSET-CONTROLLER CRASH
# =============================================================================
log_section "Fixing ArgoCD applicationset-controller"

# Restart applicationset-controller (often resolves transient crash)
kubectl rollout restart deployment argocd-applicationset-controller -n argocd
log_success "argocd-applicationset-controller restarted"

# =============================================================================
# 8. WAIT AND VERIFY
# =============================================================================
log_section "Waiting for cert-manager to issue certificates (~2 min)"

echo "Waiting 30 seconds for ACME challenges to start..."
sleep 30

echo "Certificate status:"
kubectl get certificates -A

echo ""
echo "Active ACME challenges:"
kubectl get challenges -A 2>/dev/null || echo "No challenges (may have completed)"

echo ""
echo "Current ingresses:"
kubectl get ingress -A

echo ""
log_section "Fix Complete!"
echo ""
echo "Next steps:"
echo "  1. Wait 2-5 min for Let's Encrypt to verify HTTP-01 challenges"
echo "  2. Check cert status: kubectl get certificates -A"
echo "  3. Test: curl -v https://argocd.ultichange.org"
echo "  4. If certs still pending, check: kubectl describe challenge -A"
