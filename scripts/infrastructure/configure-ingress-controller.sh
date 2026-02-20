#!/bin/bash
# =============================================================================
# Configure NGINX Ingress Controller (hostNetwork mode)
# =============================================================================
# Purpose: Install and configure NGINX Ingress Controller for VPS bare-metal.
#
#   Uses hostNetwork: true so the controller binds directly to the node's
#   ports 80 and 443. This approach:
#     - Eliminates NodePort + iptables NAT complexity
#     - Allows cert-manager ACME HTTP-01 challenges to work correctly
#     - Prevents MTU/fragmentation issues with pod-to-internet TLS connections
#     - No iptables redirects needed
#
# Usage:
#   ./configure-ingress-controller.sh
#
# Environment Variables:
#   INGRESS_CLASS   - Ingress class name (default: nginx)
#   FORCE_RECONFIGURE - Force reconfigure even if healthy (default: false)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

INGRESS_CLASS=${INGRESS_CLASS:-nginx}
FORCE_RECONFIGURE=${FORCE_RECONFIGURE:-false}

log_section "Configuring NGINX Ingress Controller (hostNetwork)"
log_info "Ingress Class: ${INGRESS_CLASS}"
log_info "Mode: hostNetwork (binds directly to node ports 80/443)"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_kubectl
ensure_helm

# =============================================================================
# INSTALL NGINX INGRESS CONTROLLER (if not present)
# =============================================================================

if ! kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
    log_info "Installing NGINX Ingress Controller..."
    ensure_namespace "ingress-nginx"

    add_helm_repo "ingress-nginx" "https://kubernetes.github.io/ingress-nginx"

    # Install with NodePort initially — we'll patch to hostNetwork below
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --set controller.ingressClassResource.name="${INGRESS_CLASS}" \
        --set controller.ingressClassResource.default=true \
        --set controller.service.type=ClusterIP \
        --set controller.watchIngressWithoutClass=true \
        --wait --timeout=10m

    log_success "NGINX Ingress Controller installed"
fi

# =============================================================================
# SWITCH TO hostNetwork MODE
# =============================================================================
# hostNetwork: true means the nginx pod shares the node's network namespace,
# binding directly to ports 80 & 443 on the host — no iptables redirect needed.
# This is the preferred approach for bare-metal/single-node VPS deployments.

CURRENT_HOSTNET=$(kubectl get deployment -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null || echo "false")

if [ "$CURRENT_HOSTNET" = "true" ] && [ "$FORCE_RECONFIGURE" != "true" ]; then
    log_success "Ingress controller already using hostNetwork - checking health..."

    READY=$(kubectl get deployment ingress-nginx-controller -n ingress-nginx \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${READY:-0}" -ge 1 ]; then
        log_success "NGINX Ingress Controller is healthy (hostNetwork mode)"
        kubectl get pods -n ingress-nginx
        kubectl get svc -n ingress-nginx
    else
        log_warning "Controller not ready, forcing reconfigure..."
        FORCE_RECONFIGURE=true
    fi
fi

if [ "$CURRENT_HOSTNET" != "true" ] || [ "$FORCE_RECONFIGURE" = "true" ]; then
    log_info "Patching ingress controller to use hostNetwork=true..."

    # Must scale to exactly 1 replica — hostNetwork cannot have 2 pods on same
    # node (port conflict). Scale before patching to avoid race conditions.
    kubectl scale deployment ingress-nginx-controller -n ingress-nginx --replicas=1

    # Patch hostNetwork
    kubectl patch deployment ingress-nginx-controller -n ingress-nginx \
        --type=merge \
        -p='{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}}}'

    log_info "Waiting for ingress controller to restart..."
    kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s || \
        log_warning "Rollout may still be in progress"

    log_success "Ingress controller now uses hostNetwork (ports 80/443 bound on host)"
fi

# =============================================================================
# ENSURE FORWARD POLICY + MASQUERADE (required for pod networking)
# =============================================================================
# Even with hostNetwork for nginx, other pods (cert-manager, app pods) still need
# correct pod-to-internet routing.

log_section "Ensuring Kubernetes pod networking"

# UFW DEFAULT_FORWARD_POLICY must be ACCEPT for Kubernetes pods to route traffic.
# Default DROP silently blocks pod egress (cert-manager ACME, image pulls, etc.)
if [ -f /etc/default/ufw ]; then
    if grep -q 'DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw; then
        sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        log_success "UFW DEFAULT_FORWARD_POLICY changed DROP -> ACCEPT"
    else
        log_success "UFW DEFAULT_FORWARD_POLICY already ACCEPT"
    fi
fi
sudo iptables -P FORWARD ACCEPT 2>/dev/null || true

# MSS clamping: prevents TCP fragmentation issues for pod TLS connections.
# Required when pod MTU differs from node MTU (e.g. Calico VXLAN adds overhead).
sudo iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    sudo iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
sudo iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    sudo iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# MASQUERADE for pod subnet (belt-and-suspenders alongside Calico natOutgoing=true)
sudo iptables -t nat -C POSTROUTING -s 192.168.0.0/16 ! -d 192.168.0.0/16 -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -I POSTROUTING 1 -s 192.168.0.0/16 ! -d 192.168.0.0/16 -j MASQUERADE

# Persist rules (best-effort)
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get install -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
    sudo netfilter-persistent save >/dev/null 2>&1 || true
fi

log_success "Pod networking rules applied and persisted"

# =============================================================================
# VERIFY
# =============================================================================

log_section "NGINX Ingress Controller Configuration Complete"

echo ""
echo "Ingress Controller:"
kubectl get pods -n ingress-nginx
echo ""
kubectl get svc -n ingress-nginx
echo ""
kubectl get ingressclass

VPS_IP=${VPS_IP:-$(hostname -I | awk '{print $1}')}
echo ""
echo "Access URLs (no port suffix needed):"
echo "  HTTP:  http://${VPS_IP}"
echo "  HTTPS: https://${VPS_IP}"
echo ""
echo "Example Ingress:"
echo "  annotations:"
echo "    cert-manager.io/cluster-issuer: letsencrypt-prod"
echo "  # No ssl-passthrough needed — nginx terminates TLS"
echo ""

log_success "NGINX Ingress Controller ready (hostNetwork mode)"
