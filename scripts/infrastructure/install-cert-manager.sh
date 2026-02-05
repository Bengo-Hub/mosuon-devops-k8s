#!/bin/bash
# =============================================================================
# Install cert-manager for TLS Certificate Management
# =============================================================================
# Purpose: Install cert-manager and configure LetsEncrypt ClusterIssuers
#
# Usage:
#   ./install-cert-manager.sh
#
# Environment Variables:
#   CERT_MANAGER_VERSION  - cert-manager version (default: latest)
#   ACME_EMAIL           - Email for LetsEncrypt (default: admin@ultimatestats.co.ke)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-latest}
ACME_EMAIL=${ACME_EMAIL:-admin@ultimatestats.co.ke}

log_section "Installing cert-manager"
log_info "Version: ${CERT_MANAGER_VERSION}"
log_info "ACME Email: ${ACME_EMAIL}"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_kubectl

# =============================================================================
# CHECK IF ALREADY INSTALLED
# =============================================================================

if kubectl get namespace cert-manager >/dev/null 2>&1; then
    # Check if cert-manager is healthy
    READY=$(kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${READY:-0}" -ge 1 ]; then
        log_success "cert-manager is already installed and healthy"
        log_info "Skipping installation"
        exit 0
    fi
fi

# =============================================================================
# INSTALL CERT-MANAGER
# =============================================================================

log_info "Installing cert-manager..."

if [ "$CERT_MANAGER_VERSION" = "latest" ]; then
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
else
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
fi

# =============================================================================
# WAIT FOR CERT-MANAGER
# =============================================================================

log_info "Waiting for cert-manager deployments..."

wait_for_deployment "cert-manager" "cert-manager" 300 || {
    log_warning "cert-manager may still be starting"
}

wait_for_deployment "cert-manager" "cert-manager-webhook" 300 || {
    log_warning "cert-manager-webhook may still be starting"
}

wait_for_deployment "cert-manager" "cert-manager-cainjector" 300 || {
    log_warning "cert-manager-cainjector may still be starting"
}

# Give webhook time to be fully ready
log_info "Waiting for webhook to be fully ready..."
sleep 10

# =============================================================================
# CREATE CLUSTER ISSUERS
# =============================================================================

log_info "Creating LetsEncrypt ClusterIssuers..."

# Staging issuer (for testing)
cat <<EOF | kubectl apply -f -
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
          class: nginx
EOF

log_success "Created letsencrypt-staging ClusterIssuer"

# Production issuer
cat <<EOF | kubectl apply -f -
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
          class: nginx
EOF

log_success "Created letsencrypt-prod ClusterIssuer"

# =============================================================================
# VERIFY INSTALLATION
# =============================================================================

log_info "Verifying installation..."

kubectl get clusterissuers
kubectl get pods -n cert-manager

# =============================================================================
# SUMMARY
# =============================================================================

log_section "cert-manager Installation Complete"

echo ""
echo "ClusterIssuers available:"
echo "  - letsencrypt-staging (for testing)"
echo "  - letsencrypt-prod (for production)"
echo ""
echo "Usage in Ingress:"
echo "  annotations:"
echo "    cert-manager.io/cluster-issuer: letsencrypt-prod"
echo "  tls:"
echo "  - hosts:"
echo "    - your-domain.com"
echo "    secretName: your-domain-tls"
echo ""

log_success "cert-manager is ready"
