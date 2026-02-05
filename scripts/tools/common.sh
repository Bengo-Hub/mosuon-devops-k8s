#!/bin/bash
# =============================================================================
# Common Functions for Mosuon DevOps Infrastructure Scripts
# =============================================================================
# Centralizes logging, cleanup logic, resource management, and utilities
# Source this file in your scripts: source "${SCRIPT_DIR}/../tools/common.sh"
#
# Usage in infrastructure scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../tools/common.sh"

# =============================================================================
# COLOR DEFINITIONS
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "${PURPLE}[STEP]${NC} $1" >&2
}

log_section() {
    echo -e "${CYAN}==========================================${NC}" >&2
    echo -e "${CYAN}$1${NC}" >&2
    echo -e "${CYAN}==========================================${NC}" >&2
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

# Check if kubectl is installed and cluster is accessible
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl command not found. Aborting."
        exit 1
    fi
    
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to cluster. Ensure KUBECONFIG is set. Aborting."
        exit 1
    fi
    
    log_success "kubectl configured and cluster reachable"
}

# Check if Helm is installed, install if missing
ensure_helm() {
    if ! command -v helm &> /dev/null; then
        log_warning "Helm not found. Installing via script..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        log_success "Helm installed"
    else
        log_success "Helm already installed"
    fi
}

# Check if jq is installed, install if missing
ensure_jq() {
    if ! command -v jq &> /dev/null; then
        log_warning "jq command not found. Attempting to install..."
        if command -v apt-get &> /dev/null; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y jq >/dev/null 2>&1 || \
            sudo apt-get update -y >/dev/null 2>&1 && sudo apt-get install -y jq >/dev/null 2>&1 || \
            log_error "Failed to install jq. Some operations may fail."
        elif command -v yum &> /dev/null; then
            yum install -y jq >/dev/null 2>&1 || sudo yum install -y jq >/dev/null 2>&1 || \
            log_error "Failed to install jq. Some operations may fail."
        fi
    fi
}

# Check if yq is installed
ensure_yq() {
    if ! command -v yq &> /dev/null; then
        log_warning "yq not found. Installing..."
        if command -v wget &> /dev/null; then
            sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
            sudo chmod +x /usr/local/bin/yq
            log_success "yq installed"
        else
            log_error "wget not available for yq installation"
            return 1
        fi
    else
        log_success "yq already installed"
    fi
}

# Check cluster health
check_cluster_health() {
    log_info "Checking cluster health..."
    
    local ready_nodes
    ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
    
    if [ "$ready_nodes" -eq 0 ]; then
        log_error "No Ready nodes found in cluster"
        return 1
    fi
    
    log_success "Cluster healthy ($ready_nodes nodes Ready)"
}

# Check if default storage class exists, install if missing
ensure_storage_class() {
    local script_dir="${1:-}"
    
    if ! kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
        log_warning "No default storage class found. Installing local-path provisioner..."
        if [ -n "$script_dir" ] && [ -f "${script_dir}/install-storage-provisioner.sh" ]; then
            "${script_dir}/install-storage-provisioner.sh"
        elif [ -f "scripts/infrastructure/install-storage-provisioner.sh" ]; then
            ./scripts/infrastructure/install-storage-provisioner.sh
        else
            # Fallback: install rancher local-path-provisioner directly
            kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
            log_success "Installed local-path-provisioner"
        fi
    else
        log_success "Default storage class available"
    fi
}

# Check if cert-manager is installed
ensure_cert_manager() {
    local script_dir="${1:-}"
    
    if ! kubectl get namespace cert-manager >/dev/null 2>&1; then
        log_warning "cert-manager not installed. Installing..."
        if [ -n "$script_dir" ] && [ -f "${script_dir}/install-cert-manager.sh" ]; then
            "${script_dir}/install-cert-manager.sh"
        elif [ -f "scripts/infrastructure/install-cert-manager.sh" ]; then
            ./scripts/infrastructure/install-cert-manager.sh
        else
            # Fallback: install cert-manager directly
            kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
            kubectl -n cert-manager rollout status deployment/cert-manager --timeout=300s
            log_success "cert-manager installed"
        fi
    else
        log_success "cert-manager already installed"
    fi
}

# =============================================================================
# HELM REPOSITORY MANAGEMENT
# =============================================================================

# Add Helm repository if not already added
add_helm_repo() {
    local repo_name=$1
    local repo_url=$2
    
    if helm repo list 2>/dev/null | grep -q "^${repo_name}"; then
        log_info "Helm repository '${repo_name}' already exists"
    else
        log_info "Adding Helm repository: ${repo_name}"
        helm repo add "${repo_name}" "${repo_url}" >/dev/null 2>&1 || true
    fi
    
    log_info "Updating Helm repositories..."
    helm repo update >/dev/null 2>&1 || true
}

# =============================================================================
# NAMESPACE MANAGEMENT
# =============================================================================

# Create namespace if it doesn't exist
ensure_namespace() {
    local namespace=$1
    
    if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
        log_success "Namespace '${namespace}' already exists"
        return 0
    else
        log_info "Creating namespace '${namespace}'..."
        kubectl create namespace "${namespace}" 2>/dev/null || {
            log_error "Failed to create namespace '${namespace}'"
            return 1
        }
        log_success "Namespace '${namespace}' created"
        return 0
    fi
}

# =============================================================================
# CLEANUP MODE FUNCTIONS
# =============================================================================

# Check if cleanup mode is active
is_cleanup_mode() {
    local cleanup_mode=${ENABLE_CLEANUP:-false}
    [ "$cleanup_mode" = "true" ]
}

# Check if resource exists and should be deleted/recreated based on cleanup mode
should_delete_and_recreate() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-default}
    
    if is_cleanup_mode; then
        return 0
    else
        if kubectl get "$resource_type" "$resource_name" -n "$namespace" >/dev/null 2>&1; then
            return 1
        else
            return 0
        fi
    fi
}

# Safely delete resource only if cleanup mode is active
safe_delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-default}
    
    if is_cleanup_mode; then
        log_info "Cleanup mode active - deleting $resource_type/$resource_name in namespace $namespace"
        kubectl delete "$resource_type" "$resource_name" -n "$namespace" --wait=true --grace-period=0 2>/dev/null || true
        return 0
    else
        log_info "Cleanup mode inactive - skipping deletion of $resource_type/$resource_name"
        return 1
    fi
}

# =============================================================================
# WAIT FUNCTIONS
# =============================================================================

# Wait for pods with label selector to be ready
wait_for_pods() {
    local namespace=$1
    local label_selector=$2
    local timeout=${3:-300}
    
    log_info "Waiting for pods with label '${label_selector}' in namespace '${namespace}'..."
    
    local end_time=$(($(date +%s) + timeout))
    
    while [ "$(date +%s)" -lt "$end_time" ]; do
        local ready_pods
        ready_pods=$(kubectl get pods -n "$namespace" -l "$label_selector" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c "True" || echo "0")
        
        local total_pods
        total_pods=$(kubectl get pods -n "$namespace" -l "$label_selector" --no-headers 2>/dev/null | wc -l || echo "0")
        
        if [ "$ready_pods" -eq "$total_pods" ] && [ "$total_pods" -gt 0 ]; then
            log_success "All $total_pods pod(s) are ready"
            return 0
        fi
        
        log_info "Waiting... ($ready_pods/$total_pods pods ready)"
        sleep 10
    done
    
    log_warning "Timeout waiting for pods"
    return 1
}

# Wait for deployment to be ready
wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}
    
    log_info "Waiting for deployment '${deployment}' in namespace '${namespace}'..."
    
    if kubectl -n "$namespace" rollout status deployment/"$deployment" --timeout="${timeout}s"; then
        log_success "Deployment '${deployment}' is ready"
        return 0
    else
        log_warning "Timeout waiting for deployment '${deployment}'"
        return 1
    fi
}

# Wait for statefulset to be ready
wait_for_statefulset() {
    local namespace=$1
    local statefulset=$2
    local timeout=${3:-300}
    
    log_info "Waiting for statefulset '${statefulset}' in namespace '${namespace}'..."
    
    if kubectl -n "$namespace" rollout status statefulset/"$statefulset" --timeout="${timeout}s"; then
        log_success "StatefulSet '${statefulset}' is ready"
        return 0
    else
        log_warning "Timeout waiting for statefulset '${statefulset}'"
        return 1
    fi
}

# =============================================================================
# SECRET MANAGEMENT
# =============================================================================

# Generate secure random password
generate_password() {
    local length=${1:-32}
    openssl rand -base64 48 | tr -d "=+/" | cut -c1-"$length"
}

# Get secret value from Kubernetes
get_secret_value() {
    local namespace=$1
    local secret_name=$2
    local key=$3
    
    kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d
}

# =============================================================================
# DATABASE UTILITIES
# =============================================================================

# Wait for PostgreSQL to be ready
wait_for_postgresql() {
    local namespace=${1:-infra}
    local timeout=${2:-300}
    local pod_name=${3:-postgresql-0}
    
    log_info "Waiting for PostgreSQL in namespace '${namespace}'..."
    
    local end_time=$(($(date +%s) + timeout))
    
    while [ "$(date +%s)" -lt "$end_time" ]; do
        if kubectl -n "$namespace" get pod "$pod_name" >/dev/null 2>&1; then
            local phase
            phase=$(kubectl -n "$namespace" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null)
            
            if [ "$phase" = "Running" ]; then
                # Check if PostgreSQL is accepting connections
                if kubectl -n "$namespace" exec "$pod_name" -- pg_isready -U postgres >/dev/null 2>&1; then
                    log_success "PostgreSQL is ready"
                    return 0
                fi
            fi
        fi
        
        log_info "Waiting for PostgreSQL..."
        sleep 10
    done
    
    log_error "Timeout waiting for PostgreSQL"
    return 1
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Check if running in CI/CD environment
is_ci_environment() {
    [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${GITLAB_CI:-}" ]
}

# Get current git commit hash
get_git_commit() {
    if [ -n "${GITHUB_SHA:-}" ]; then
        echo "${GITHUB_SHA:0:8}"
    else
        git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown"
    fi
}

log_info "Common utilities loaded successfully"
