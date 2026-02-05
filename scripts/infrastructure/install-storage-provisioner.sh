#!/bin/bash
# =============================================================================
# Install Storage Provisioner for Dynamic PVC Provisioning
# =============================================================================
# Purpose: Install local-path-provisioner for dynamic PersistentVolumeClaim support
#
# Usage:
#   ./install-storage-provisioner.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

log_section "Installing Storage Provisioner"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_kubectl

# =============================================================================
# CHECK IF ALREADY INSTALLED
# =============================================================================

# Check for existing default storage class
if kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
    DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
    log_success "Default storage class already exists: ${DEFAULT_SC}"
    log_info "Skipping installation"
    exit 0
fi

# Check if local-path-provisioner is installed but not default
if kubectl get storageclass local-path >/dev/null 2>&1; then
    log_info "local-path storage class exists but not default, setting as default..."
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    log_success "Set local-path as default storage class"
    exit 0
fi

# =============================================================================
# INSTALL LOCAL-PATH-PROVISIONER
# =============================================================================

log_info "Installing Rancher local-path-provisioner..."

kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# =============================================================================
# WAIT FOR PROVISIONER
# =============================================================================

log_info "Waiting for local-path-provisioner deployment..."

wait_for_deployment "local-path-storage" "local-path-provisioner" 180 || {
    log_warning "local-path-provisioner may still be starting"
}

# =============================================================================
# VERIFY INSTALLATION
# =============================================================================

log_info "Verifying storage class..."

kubectl get storageclass

# Check if local-path is now the default
if kubectl get storageclass local-path -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null | grep -q "true"; then
    log_success "local-path is set as default storage class"
else
    log_info "Setting local-path as default storage class..."
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true
fi

# =============================================================================
# SUMMARY
# =============================================================================

log_section "Storage Provisioner Installation Complete"

echo ""
echo "Storage Classes:"
kubectl get storageclass
echo ""
echo "PVCs will now be automatically provisioned on local storage."
echo "Data is stored on the node at: /opt/local-path-provisioner"
echo ""
echo "⚠️  Note: local-path storage is NOT suitable for production workloads"
echo "    that require high availability or data replication."
echo ""

log_success "Storage provisioner is ready"
