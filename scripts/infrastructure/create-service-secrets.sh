#!/bin/bash
# =============================================================================
# Create Service Secrets for Mosuon Applications
# =============================================================================
# Purpose: Creates Kubernetes secrets for service applications with database
#          connection strings and other required credentials.
#
# Usage:
#   SERVICE_NAME=game-stats-api NAMESPACE=mosuon ./create-service-secrets.sh
#
# Environment Variables:
#   SERVICE_NAME      - Name of the service (e.g., game-stats-api)
#   NAMESPACE         - Kubernetes namespace for the service (default: mosuon)
#   SECRET_NAME       - Name of the secret to create (default: ${SERVICE_NAME}-secrets)
#   DB_NAME           - Database name (default: inferred from SERVICE_NAME)
#   DB_USER           - Database user (default: ${DB_NAME}_user)
#   DB_NAMESPACE      - Namespace where PostgreSQL runs (default: infra)
#   POSTGRES_PASSWORD - Database password (retrieved from K8s secret if not set)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

SERVICE_NAME=${SERVICE_NAME:-""}
NAMESPACE=${NAMESPACE:-"mosuon"}
DB_NAMESPACE=${DB_NAMESPACE:-"infra"}

if [ -z "$SERVICE_NAME" ]; then
    log_error "SERVICE_NAME must be set"
    exit 1
fi

# Infer secret name
SECRET_NAME=${SECRET_NAME:-"${SERVICE_NAME}-secrets"}

# Infer database name from service name
# e.g., game-stats-api -> game_stats
if [ -z "${DB_NAME:-}" ]; then
    DB_NAME=$(echo "$SERVICE_NAME" | sed -E 's/-(api|backend|service|ui)$//' | tr '-' '_')
fi

# Infer database user
DB_USER=${DB_USER:-"${DB_NAME}_user"}

log_section "Creating Secrets for Service: ${SERVICE_NAME}"
log_info "Namespace: ${NAMESPACE}"
log_info "Secret Name: ${SECRET_NAME}"
log_info "Database: ${DB_NAME}"
log_info "Database User: ${DB_USER}"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_kubectl

# Create namespace if needed
ensure_namespace "${NAMESPACE}"

# =============================================================================
# GET DATABASE PASSWORD
# =============================================================================

# Try to get password from environment or K8s secret
if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    log_info "Retrieving PostgreSQL password from cluster..."
    POSTGRES_PASSWORD=$(get_secret_value "$DB_NAMESPACE" "postgresql" "postgres-password" || echo "")
    
    if [ -z "$POSTGRES_PASSWORD" ]; then
        POSTGRES_PASSWORD=$(get_secret_value "$DB_NAMESPACE" "postgresql" "password" || echo "")
    fi
    
    if [ -z "$POSTGRES_PASSWORD" ]; then
        log_error "Could not retrieve PostgreSQL password"
        log_error "Set POSTGRES_PASSWORD environment variable or ensure postgresql secret exists"
        exit 1
    fi
fi

# =============================================================================
# BUILD CONNECTION STRINGS
# =============================================================================

PG_HOST="postgresql.${DB_NAMESPACE}.svc.cluster.local"
PG_PORT="5432"
REDIS_HOST="redis-master.${DB_NAMESPACE}.svc.cluster.local"
REDIS_PORT="6379"

DATABASE_URL="postgresql://${DB_USER}:${POSTGRES_PASSWORD}@${PG_HOST}:${PG_PORT}/${DB_NAME}?sslmode=disable"
REDIS_URL="redis://:${POSTGRES_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/0"

# Generate additional secrets
JWT_SECRET=${JWT_SECRET:-$(generate_password 64)}
API_SECRET=${API_SECRET:-$(generate_password 32)}

# =============================================================================
# CREATE OR UPDATE SECRET
# =============================================================================

log_info "Creating secret '${SECRET_NAME}' in namespace '${NAMESPACE}'..."

# Check if secret already exists
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    log_info "Secret already exists - updating..."
    kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || true
fi

# Create secret with common keys
kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
    --from-literal=DATABASE_URL="${DATABASE_URL}" \
    --from-literal=POSTGRES_URL="${DATABASE_URL}" \
    --from-literal=REDIS_URL="${REDIS_URL}" \
    --from-literal=REDIS_PASSWORD="${POSTGRES_PASSWORD}" \
    --from-literal=JWT_SECRET="${JWT_SECRET}" \
    --from-literal=API_SECRET="${API_SECRET}" \
    --from-literal=DB_HOST="${PG_HOST}" \
    --from-literal=DB_PORT="${PG_PORT}" \
    --from-literal=DB_NAME="${DB_NAME}" \
    --from-literal=DB_USER="${DB_USER}" \
    --from-literal=DB_PASSWORD="${POSTGRES_PASSWORD}"

log_success "Secret '${SECRET_NAME}' created"

# =============================================================================
# VERIFY SECRET
# =============================================================================

log_info "Verifying secret..."

KEYS=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o json | jq -r '.data | keys[]' 2>/dev/null | tr '\n' ', ')
log_success "Secret keys: ${KEYS}"

# =============================================================================
# SUMMARY
# =============================================================================

log_section "Secret Creation Complete"

echo ""
echo "Secret Details:"
echo "  Name: ${SECRET_NAME}"
echo "  Namespace: ${NAMESPACE}"
echo "  Keys: DATABASE_URL, REDIS_URL, JWT_SECRET, API_SECRET, DB_* fields"
echo ""
echo "Usage in Deployment:"
echo "  envFrom:"
echo "    - secretRef:"
echo "        name: ${SECRET_NAME}"
echo ""
echo "Or individual keys:"
echo "  env:"
echo "    - name: DATABASE_URL"
echo "      valueFrom:"
echo "        secretKeyRef:"
echo "          name: ${SECRET_NAME}"
echo "          key: DATABASE_URL"
echo ""

log_success "Service secrets ready for ${SERVICE_NAME}"
