#!/bin/bash
# =============================================================================
# Production-Ready Argo CD Installation for Mosuon
# =============================================================================
# Purpose: Install and configure ArgoCD with TLS ingress for production access
#
# Usage:
#   ARGOCD_DOMAIN=argocd.ultimatestats.co.ke ./install-argocd.sh
#
# Environment Variables:
#   ARGOCD_DOMAIN    - Domain for ArgoCD (default: argocd.ultimatestats.co.ke)
#   VPS_IP           - VPS IP for DNS hint (optional)
#   FORCE_UPGRADE    - Force upgrade even if healthy (default: false)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "${SCRIPT_DIR}/../tools/common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

ARGOCD_DOMAIN=${ARGOCD_DOMAIN:-argocd.ultimatestats.co.ke}
VPS_IP=${VPS_IP:-207.180.237.35}
FORCE_UPGRADE=${FORCE_UPGRADE:-false}

log_section "Installing Argo CD (Production)"
log_info "Domain: ${ARGOCD_DOMAIN}"
log_info "VPS IP: ${VPS_IP}"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_kubectl
ensure_helm
ensure_cert_manager "${SCRIPT_DIR}"

# Create namespace
ensure_namespace "argocd"

# =============================================================================
# INSTALL ARGO CD
# =============================================================================

# Check if Argo CD is already installed and healthy
if kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
    READY_REPLICAS=$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED_REPLICAS=$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    
    READY_REPLICAS=${READY_REPLICAS:-0}
    DESIRED_REPLICAS=${DESIRED_REPLICAS:-0}
    
    if [ "$READY_REPLICAS" -ge 1 ] && [ "$READY_REPLICAS" -eq "$DESIRED_REPLICAS" ] && [ "$FORCE_UPGRADE" != "true" ]; then
        log_success "Argo CD already installed and healthy - skipping upgrade"
        log_info "To force upgrade, set FORCE_UPGRADE=true"
    else
        if [ "$FORCE_UPGRADE" = "true" ]; then
            log_info "Force upgrade requested. Upgrading Argo CD..."
        else
            log_info "Argo CD exists but not healthy. Upgrading..."
        fi
        
        kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null 2>&1 || {
            log_warning "Some resources may already exist - continuing"
        }
        log_success "Argo CD manifests applied"
    fi
else
    log_info "Installing Argo CD..."
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null 2>&1 || {
        log_warning "Some resources may already exist - continuing"
    }
    log_success "Argo CD installed"
fi

# =============================================================================
# WAIT FOR ARGO CD
# =============================================================================

log_info "Waiting for Argo CD to be ready..."
wait_for_deployment "argocd" "argocd-server" 300 || log_warning "ArgoCD server may still be starting"

# =============================================================================
# CONFIGURE INGRESS
# =============================================================================

log_info "Configuring production ingress with TLS..."

cat > /tmp/argocd-ingress-prod.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${ARGOCD_DOMAIN}
    secretName: argocd-tls
  rules:
  - host: ${ARGOCD_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
EOF

kubectl apply -f /tmp/argocd-ingress-prod.yaml
log_success "Ingress configured for ${ARGOCD_DOMAIN}"

# =============================================================================
# CREATE CLUSTER ISSUER (if not exists)
# =============================================================================

if ! kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1; then
    log_info "Creating LetsEncrypt ClusterIssuer..."
    cat > /tmp/letsencrypt-prod.yaml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@ultimatestats.co.ke
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
    kubectl apply -f /tmp/letsencrypt-prod.yaml
    log_success "LetsEncrypt ClusterIssuer created"
else
    log_success "LetsEncrypt ClusterIssuer already exists"
fi

# =============================================================================
# GET INITIAL ADMIN PASSWORD
# =============================================================================

echo ""
log_section "Argo CD Installation Complete"
echo ""
echo -e "${BLUE}Access Information:${NC}"
echo "  URL: https://${ARGOCD_DOMAIN}"
echo "  Username: admin"

if kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
    INITIAL_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")
    if [ -n "$INITIAL_PASSWORD" ]; then
        echo "  Password: $INITIAL_PASSWORD"
    else
        echo "  Password: (already changed or unavailable)"
    fi
else
    echo "  Password: (already changed)"
fi

echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Ensure DNS: ${ARGOCD_DOMAIN} → ${VPS_IP}"
echo "2. Wait for cert-manager to provision TLS (~2 mins)"
echo "3. Visit https://${ARGOCD_DOMAIN} and login"
echo "4. Change admin password immediately"
echo "5. Add repository access for GitOps"
echo ""
echo -e "${BLUE}Alternative Access (port-forward):${NC}"
echo "kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "Then visit: https://localhost:8080"
echo ""

log_success "ArgoCD installation complete"
