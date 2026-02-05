#!/bin/bash
# =============================================================================
# Production-Ready Database Installation for Mosuon
# =============================================================================
# Purpose: Install PostgreSQL and Redis with production configurations
#
# Usage:
#   POSTGRES_PASSWORD=xxx ./install-databases.sh
#
# Environment Variables:
#   NAMESPACE           - Target namespace (default: infra)
#   POSTGRES_PASSWORD   - PostgreSQL password (required or auto-generated)
#   REDIS_PASSWORD      - Redis password (default: same as POSTGRES_PASSWORD)
#   ENABLE_CLEANUP      - Delete existing resources before installing (default: false)
#   ONLY_COMPONENT      - Install only specific component: all, postgres, redis (default: all)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
MANIFESTS_DIR="${REPO_ROOT}/manifests/databases"
source "${SCRIPT_DIR}/../tools/common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

NAMESPACE=${NAMESPACE:-infra}
ONLY_COMPONENT=${ONLY_COMPONENT:-all}
ENABLE_CLEANUP=${ENABLE_CLEANUP:-false}

log_section "Installing Shared Infrastructure Databases (Production)"
log_info "Namespace: ${NAMESPACE}"
log_info "Component: ${ONLY_COMPONENT}"

if [ "${ENABLE_CLEANUP}" = "true" ]; then
    log_warning "⚠️  CLEANUP MODE ENABLED - Will delete existing resources and data"
else
    log_info "Cleanup mode disabled - Will update existing resources"
fi

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_kubectl
check_cluster_health
ensure_storage_class "${SCRIPT_DIR}"
ensure_helm

# Add Bitnami repository for Redis
add_helm_repo "bitnami" "https://charts.bitnami.com/bitnami"

# Create namespace
ensure_namespace "${NAMESPACE}"

# =============================================================================
# PASSWORD MANAGEMENT
# =============================================================================

# Generate passwords if not provided
if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    POSTGRES_PASSWORD=$(generate_password 32)
    log_warning "Generated PostgreSQL password (save this securely)"
fi

REDIS_PASSWORD=${REDIS_PASSWORD:-${POSTGRES_PASSWORD}}

# =============================================================================
# POSTGRESQL INSTALLATION
# =============================================================================

POSTGRES_DEPLOYED=false

if [ "${ONLY_COMPONENT}" != "redis" ]; then
    log_section "PostgreSQL Installation"
    
    # Cleanup if enabled
    if [ "${ENABLE_CLEANUP}" = "true" ]; then
        log_warning "Cleanup mode: Deleting existing PostgreSQL resources..."
        kubectl delete statefulset postgresql -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
        kubectl delete pvc -n "${NAMESPACE}" -l app=postgresql --wait=true 2>/dev/null || true
        helm uninstall postgresql -n "${NAMESPACE}" 2>/dev/null || true
        sleep 5
    fi
    
    # Create PostgreSQL secret if not exists
    if ! kubectl get secret postgresql -n "${NAMESPACE}" >/dev/null 2>&1; then
        log_info "Creating PostgreSQL secret..."
        kubectl create secret generic postgresql \
            -n "${NAMESPACE}" \
            --from-literal=password="${POSTGRES_PASSWORD}" \
            --from-literal=postgres-password="${POSTGRES_PASSWORD}" \
            --from-literal=admin-user-password="${POSTGRES_PASSWORD}"
        log_success "PostgreSQL secret created"
    else
        log_info "PostgreSQL secret already exists - reusing"
    fi
    
    # Check for custom manifests or use Helm
    if [ -f "${MANIFESTS_DIR}/postgresql-statefulset.yaml" ]; then
        log_info "Using custom StatefulSet manifests..."
        kubectl apply -f "${MANIFESTS_DIR}/postgresql-statefulset.yaml"
        
        # Wait for PostgreSQL
        log_info "Waiting for PostgreSQL to be ready (timeout: 5 minutes)..."
        wait_for_statefulset "${NAMESPACE}" "postgresql" 300 || {
            log_warning "PostgreSQL may still be starting..."
            kubectl get pod -n "${NAMESPACE}" -l app=postgresql
        }
    else
        log_info "Using Bitnami Helm chart for PostgreSQL..."
        helm upgrade --install postgresql bitnami/postgresql \
            --namespace "${NAMESPACE}" \
            --set auth.postgresPassword="${POSTGRES_PASSWORD}" \
            --set primary.persistence.size=20Gi \
            --set primary.resources.requests.memory=256Mi \
            --set primary.resources.requests.cpu=100m \
            --set primary.resources.limits.memory=512Mi \
            --set primary.resources.limits.cpu=500m \
            --wait --timeout=10m
    fi
    
    # Verify PostgreSQL
    if kubectl get pod -n "${NAMESPACE}" -l app=postgresql 2>/dev/null | grep -q "Running"; then
        log_success "PostgreSQL is ready and healthy"
        POSTGRES_DEPLOYED=true
    elif kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql 2>/dev/null | grep -q "Running"; then
        log_success "PostgreSQL (Helm) is ready and healthy"
        POSTGRES_DEPLOYED=true
    else
        log_warning "PostgreSQL deployment may have issues"
        kubectl get pods -n "${NAMESPACE}" || true
    fi
fi

# =============================================================================
# REDIS INSTALLATION
# =============================================================================

REDIS_DEPLOYED=false

if [ "${ONLY_COMPONENT}" != "postgres" ]; then
    log_section "Redis Installation"
    
    # Cleanup if enabled
    if [ "${ENABLE_CLEANUP}" = "true" ]; then
        log_warning "Cleanup mode: Deleting existing Redis resources..."
        kubectl delete statefulset redis -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
        kubectl delete pvc -n "${NAMESPACE}" -l app=redis --wait=true 2>/dev/null || true
        helm uninstall redis -n "${NAMESPACE}" 2>/dev/null || true
        sleep 5
    fi
    
    # Create Redis secret if not exists
    if ! kubectl get secret redis -n "${NAMESPACE}" >/dev/null 2>&1; then
        log_info "Creating Redis secret..."
        kubectl create secret generic redis \
            -n "${NAMESPACE}" \
            --from-literal=redis-password="${REDIS_PASSWORD}"
        log_success "Redis secret created"
    else
        log_info "Redis secret already exists - reusing"
    fi
    
    # Check for custom manifests or use Helm
    if [ -f "${MANIFESTS_DIR}/redis-statefulset.yaml" ]; then
        log_info "Using custom StatefulSet manifests..."
        kubectl apply -f "${MANIFESTS_DIR}/redis-statefulset.yaml"
        
        # Wait for Redis
        log_info "Waiting for Redis to be ready (timeout: 5 minutes)..."
        wait_for_statefulset "${NAMESPACE}" "redis" 300 || {
            log_warning "Redis may still be starting..."
            kubectl get pod -n "${NAMESPACE}" -l app=redis
        }
    else
        log_info "Using Bitnami Helm chart for Redis..."
        helm upgrade --install redis bitnami/redis \
            --namespace "${NAMESPACE}" \
            --set auth.password="${REDIS_PASSWORD}" \
            --set master.persistence.size=8Gi \
            --set master.resources.requests.memory=128Mi \
            --set master.resources.requests.cpu=50m \
            --set master.resources.limits.memory=256Mi \
            --set master.resources.limits.cpu=250m \
            --set replica.replicaCount=0 \
            --wait --timeout=10m
    fi
    
    # Verify Redis
    if kubectl get pod -n "${NAMESPACE}" -l app=redis 2>/dev/null | grep -q "Running"; then
        log_success "Redis is ready and healthy"
        REDIS_DEPLOYED=true
    elif kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=redis 2>/dev/null | grep -q "Running"; then
        log_success "Redis (Helm) is ready and healthy"
        REDIS_DEPLOYED=true
    else
        log_warning "Redis deployment may have issues"
        kubectl get pods -n "${NAMESPACE}" || true
    fi
fi

# =============================================================================
# SUMMARY
# =============================================================================

log_section "Database Installation Summary"

echo ""
if [ "$POSTGRES_DEPLOYED" = "true" ]; then
    echo "✅ PostgreSQL deployed in namespace: ${NAMESPACE}"
    echo "   Host: postgresql.${NAMESPACE}.svc.cluster.local"
    echo "   Port: 5432"
else
    echo "⚠️  PostgreSQL not deployed (ONLY_COMPONENT=${ONLY_COMPONENT})"
fi

echo ""
if [ "$REDIS_DEPLOYED" = "true" ]; then
    echo "✅ Redis deployed in namespace: ${NAMESPACE}"
    echo "   Host: redis-master.${NAMESPACE}.svc.cluster.local"
    echo "   Port: 6379"
else
    echo "⚠️  Redis not deployed (ONLY_COMPONENT=${ONLY_COMPONENT})"
fi

echo ""
echo "Retrieve passwords:"
echo "  PostgreSQL: kubectl get secret postgresql -n ${NAMESPACE} -o jsonpath='{.data.postgres-password}' | base64 -d"
echo "  Redis: kubectl get secret redis -n ${NAMESPACE} -o jsonpath='{.data.redis-password}' | base64 -d"
echo ""

log_success "Database installation complete"
