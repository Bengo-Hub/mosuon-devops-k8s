#!/bin/bash
set -euo pipefail

# =============================================================================
# Install Vertical Pod Autoscaler (VPA)
# =============================================================================
# Installs VPA components in kube-system using the upstream manifests.
# Version is configurable via VPA_VERSION (defaults to 1.2.0).
# The script merges the per-component manifests into a single file so
# `kubectl apply` can be used deterministically.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
MANIFESTS_DIR="${REPO_ROOT}/manifests/vpa"
source "${SCRIPT_DIR}/../tools/common.sh"

# Configuration
VPA_VERSION=${VPA_VERSION:-1.2.0}
VPA_MANIFEST="${MANIFESTS_DIR}/vpa-v${VPA_VERSION}.yaml"
VPA_BASE_URL="https://raw.githubusercontent.com/kubernetes/autoscaler/vertical-pod-autoscaler-${VPA_VERSION}/vertical-pod-autoscaler/deploy"
COMPONENTS=(
  "vpa-v1-crd-gen.yaml"
  "vpa-rbac.yaml"
  "recommender-deployment.yaml"
  "updater-deployment.yaml"
  "admission-controller-deployment.yaml"
)

log_section "Installing Vertical Pod Autoscaler (VPA) v${VPA_VERSION}"
check_kubectl

if kubectl get deployment vpa-recommender -n kube-system >/dev/null 2>&1; then
  log_success "VPA already installed"
  kubectl get pods -n kube-system | grep vpa || true
  exit 0
fi

mkdir -p "${MANIFESTS_DIR}"
TEMP_DIR=$(mktemp -d)
trap "rm -rf \"${TEMP_DIR}\"" EXIT

log_info "Downloading VPA component manifests (version ${VPA_VERSION})"
for component in "${COMPONENTS[@]}"; do
  target="${TEMP_DIR}/${component}"
  url="${VPA_BASE_URL}/${component}"
  if curl -fsSL "$url" -o "$target"; then
    log_success "Downloaded ${component}"
    continue
  fi

  # Try a simplified name in case upstream dropped the suffix
  alt_component="$(echo "$component" | sed 's/-gen//g')"
  alt_url="${VPA_BASE_URL}/${alt_component}"
  if curl -fsSL "$alt_url" -o "$target"; then
    log_success "Downloaded ${component} via ${alt_component}"
    continue
  fi

  log_warning "Failed to download ${component} (${url})"
  rm -f "$target"
done

log_info "Building consolidated manifest at ${VPA_MANIFEST}"
cat "${TEMP_DIR}"/*.yaml > "$VPA_MANIFEST" || true
if [ ! -s "$VPA_MANIFEST" ]; then
  log_error "Combined VPA manifest is empty"
  exit 1
fi

log_info "Applying VPA manifest"
kubectl apply -f "$VPA_MANIFEST"

log_info "Waiting for VPA components to report Ready"
kubectl rollout status deployment/vpa-recommender -n kube-system --timeout=120s || log_warning "vpa-recommender still starting"
kubectl rollout status deployment/vpa-updater -n kube-system --timeout=120s || log_warning "vpa-updater still starting"
kubectl rollout status deployment/vpa-admission-controller -n kube-system --timeout=120s || log_warning "vpa-admission-controller still starting"

log_section "VPA Installation Complete"
log_info "Current VPA pods:"
kubectl get pods -n kube-system | grep vpa || true
