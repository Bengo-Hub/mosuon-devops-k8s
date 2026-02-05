#!/bin/bash
# =============================================================================
# Configure NGINX Ingress Controller
# =============================================================================
# Purpose: Install and configure NGINX Ingress Controller for external access
#
# Usage:
#   ./configure-ingress-controller.sh
#
# Environment Variables:
#   INGRESS_CLASS     - Ingress class name (default: nginx)
#   SERVICE_TYPE      - Service type: NodePort or LoadBalancer (default: NodePort)
#   HTTP_PORT         - NodePort for HTTP (default: 30080)
#   HTTPS_PORT        - NodePort for HTTPS (default: 30443)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

INGRESS_CLASS=${INGRESS_CLASS:-nginx}
SERVICE_TYPE=${SERVICE_TYPE:-NodePort}
HTTP_PORT=${HTTP_PORT:-30080}
HTTPS_PORT=${HTTPS_PORT:-30443}

log_section "Configuring NGINX Ingress Controller"
log_info "Ingress Class: ${INGRESS_CLASS}"
log_info "Service Type: ${SERVICE_TYPE}"
if [ "$SERVICE_TYPE" = "NodePort" ]; then
    log_info "HTTP Port: ${HTTP_PORT}"
    log_info "HTTPS Port: ${HTTPS_PORT}"
fi

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_kubectl
ensure_helm

# =============================================================================
# CHECK IF ALREADY INSTALLED
# =============================================================================

if kubectl get namespace ingress-nginx >/dev/null 2>&1; then
    # Check if ingress controller is healthy
    READY=$(kubectl get deployment ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${READY:-0}" -ge 1 ]; then
        log_success "NGINX Ingress Controller is already installed and healthy"
        log_info "Checking configuration..."
        
        # Verify service type and ports
        CURRENT_TYPE=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
        log_info "Current service type: ${CURRENT_TYPE}"
        
        if [ "$CURRENT_TYPE" = "NodePort" ]; then
            CURRENT_HTTP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "")
            CURRENT_HTTPS=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || echo "")
            log_info "Current HTTP NodePort: ${CURRENT_HTTP}"
            log_info "Current HTTPS NodePort: ${CURRENT_HTTPS}"
        fi
        
        exit 0
    fi
fi

# =============================================================================
# ADD HELM REPOSITORY
# =============================================================================

add_helm_repo "ingress-nginx" "https://kubernetes.github.io/ingress-nginx"

# =============================================================================
# INSTALL NGINX INGRESS CONTROLLER
# =============================================================================

log_info "Installing NGINX Ingress Controller..."

HELM_ARGS=(
    "--namespace" "ingress-nginx"
    "--create-namespace"
    "--set" "controller.ingressClassResource.name=${INGRESS_CLASS}"
    "--set" "controller.ingressClassResource.default=true"
    "--set" "controller.service.type=${SERVICE_TYPE}"
    "--set" "controller.watchIngressWithoutClass=true"
)

if [ "$SERVICE_TYPE" = "NodePort" ]; then
    HELM_ARGS+=(
        "--set" "controller.service.nodePorts.http=${HTTP_PORT}"
        "--set" "controller.service.nodePorts.https=${HTTPS_PORT}"
    )
fi

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    "${HELM_ARGS[@]}" \
    --wait --timeout=10m

# =============================================================================
# WAIT FOR INGRESS CONTROLLER
# =============================================================================

log_info "Waiting for NGINX Ingress Controller..."

wait_for_deployment "ingress-nginx" "ingress-nginx-controller" 300 || {
    log_warning "Ingress controller may still be starting"
}

# =============================================================================
# VERIFY INSTALLATION
# =============================================================================

log_info "Verifying installation..."

kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
kubectl get ingressclass

# =============================================================================
# SUMMARY
# =============================================================================

log_section "NGINX Ingress Controller Installation Complete"

echo ""
echo "Ingress Controller Details:"
echo "  Namespace: ingress-nginx"
echo "  Class: ${INGRESS_CLASS} (default)"
echo "  Service Type: ${SERVICE_TYPE}"

if [ "$SERVICE_TYPE" = "NodePort" ]; then
    VPS_IP=${VPS_IP:-$(hostname -I | awk '{print $1}')}
    echo ""
    echo "Access URLs:"
    echo "  HTTP:  http://${VPS_IP}:${HTTP_PORT}"
    echo "  HTTPS: https://${VPS_IP}:${HTTPS_PORT}"
    echo ""
    echo "Configure iptables for port 80/443 (if needed):"
    echo "  iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port ${HTTP_PORT}"
    echo "  iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port ${HTTPS_PORT}"
fi

echo ""
echo "Example Ingress:"
echo "  apiVersion: networking.k8s.io/v1"
echo "  kind: Ingress"
echo "  metadata:"
echo "    name: example"
echo "    annotations:"
echo "      cert-manager.io/cluster-issuer: letsencrypt-prod"
echo "  spec:"
echo "    ingressClassName: ${INGRESS_CLASS}"
echo "    tls:"
echo "    - hosts:"
echo "      - example.ultimatestats.co.ke"
echo "      secretName: example-tls"
echo "    rules:"
echo "    - host: example.ultimatestats.co.ke"
echo "      http:"
echo "        paths:"
echo "        - path: /"
echo "          pathType: Prefix"
echo "          backend:"
echo "            service:"
echo "              name: example-service"
echo "              port:"
echo "                number: 80"
echo ""

log_success "NGINX Ingress Controller is ready"
