#!/bin/bash
# =============================================================================
# Create Service-Specific Database on Shared PostgreSQL
# =============================================================================
# Purpose: Creates a dedicated database and user for a service on the shared
#          PostgreSQL instance in the infra namespace.
#
# Usage:
#   SERVICE_DB_NAME=game_stats APP_NAME=game-stats-api ./create-service-database.sh
#
# Environment Variables:
#   APP_NAME          - Name of the application (used to infer DB name if SERVICE_DB_NAME not set)
#   SERVICE_DB_NAME   - Database name to create (default: inferred from APP_NAME)
#   SERVICE_DB_USER   - Database user to create (default: ${SERVICE_DB_NAME}_user)
#   NAMESPACE         - Kubernetes namespace for the service (default: mosuon)
#   DB_NAMESPACE      - Namespace where PostgreSQL is running (default: infra)
#   POSTGRES_PASSWORD - Password for the new database user (auto-retrieved from K8s secret)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

APP_NAME=${APP_NAME:-""}
NAMESPACE=${NAMESPACE:-"mosuon"}
DB_NAMESPACE=${DB_NAMESPACE:-"infra"}

# Infer SERVICE_DB_NAME from APP_NAME if not provided
# e.g., game-stats-api -> game_stats
if [ -z "${SERVICE_DB_NAME:-}" ]; then
    if [ -n "$APP_NAME" ]; then
        # Remove common suffixes and convert to underscore format
        SERVICE_DB_NAME=$(echo "$APP_NAME" | sed -E 's/-(api|backend|service|ui)$//' | tr '-' '_')
    else
        log_error "Either SERVICE_DB_NAME or APP_NAME must be set"
        exit 1
    fi
fi

# Infer SERVICE_DB_USER if not provided
SERVICE_DB_USER=${SERVICE_DB_USER:-"${SERVICE_DB_NAME}_user"}

log_section "Creating Database for Service: ${APP_NAME:-$SERVICE_DB_NAME}"
log_info "Database Name: ${SERVICE_DB_NAME}"
log_info "Database User: ${SERVICE_DB_USER}"
log_info "DB Namespace: ${DB_NAMESPACE}"
log_info "Service Namespace: ${NAMESPACE}"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_kubectl

# Check if PostgreSQL is running
if ! kubectl -n "$DB_NAMESPACE" get statefulset postgresql >/dev/null 2>&1; then
    log_error "PostgreSQL StatefulSet not found in namespace ${DB_NAMESPACE}"
    log_error "Please run the database installation first"
    exit 1
fi

# Wait for PostgreSQL to be ready
wait_for_postgresql "$DB_NAMESPACE" 180

# =============================================================================
# GET ADMIN PASSWORD
# =============================================================================

log_info "Retrieving PostgreSQL admin credentials..."

# Try to get admin_user password first (preferred)
ADMIN_USER="admin_user"
ADMIN_PASSWORD=$(get_secret_value "$DB_NAMESPACE" "postgresql" "admin-user-password" || echo "")

# Fallback to postgres user if admin_user not available
if [ -z "$ADMIN_PASSWORD" ]; then
    log_info "admin_user password not found, trying postgres password..."
    ADMIN_USER="postgres"
    ADMIN_PASSWORD=$(get_secret_value "$DB_NAMESPACE" "postgresql" "postgres-password" || echo "")
    
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(get_secret_value "$DB_NAMESPACE" "postgresql" "password" || echo "")
    fi
fi

if [ -z "$ADMIN_PASSWORD" ]; then
    log_error "Could not retrieve PostgreSQL admin password from secrets"
    log_error "Ensure the 'postgresql' secret exists in namespace '${DB_NAMESPACE}'"
    exit 1
fi

log_success "Retrieved credentials for user: ${ADMIN_USER}"

# =============================================================================
# GET SERVICE USER PASSWORD
# =============================================================================

# Use POSTGRES_PASSWORD if provided, otherwise generate a new one
if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    POSTGRES_PASSWORD=$(generate_password 32)
    log_info "Generated new password for ${SERVICE_DB_USER}"
else
    log_info "Using provided POSTGRES_PASSWORD for ${SERVICE_DB_USER}"
fi

# =============================================================================
# CREATE DATABASE AND USER
# =============================================================================

log_info "Creating database '${SERVICE_DB_NAME}' and user '${SERVICE_DB_USER}'..."

# Find the PostgreSQL pod
PG_POD=$(kubectl -n "$DB_NAMESPACE" get pod -l app=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
         kubectl -n "$DB_NAMESPACE" get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
         echo "postgresql-0")

log_info "Using PostgreSQL pod: ${PG_POD}"

# Execute database creation SQL
kubectl -n "$DB_NAMESPACE" exec -i "$PG_POD" -- psql -U "$ADMIN_USER" -d postgres <<EOF || {
    log_warning "Database creation may have partially failed - checking state..."
}
-- Create database if not exists
SELECT 'CREATE DATABASE ${SERVICE_DB_NAME}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${SERVICE_DB_NAME}')\gexec

-- Create user if not exists (using DO block for idempotency)
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${SERVICE_DB_USER}') THEN
        CREATE USER ${SERVICE_DB_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User ${SERVICE_DB_USER} created';
    ELSE
        -- Update password if user exists
        ALTER USER ${SERVICE_DB_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User ${SERVICE_DB_USER} password updated';
    END IF;
END
\$\$;

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE ${SERVICE_DB_NAME} TO ${SERVICE_DB_USER};
GRANT CONNECT ON DATABASE ${SERVICE_DB_NAME} TO ${SERVICE_DB_USER};
EOF

# Grant schema privileges (must connect to the specific database)
kubectl -n "$DB_NAMESPACE" exec -i "$PG_POD" -- psql -U "$ADMIN_USER" -d "$SERVICE_DB_NAME" <<EOF || true
-- Grant schema privileges
GRANT ALL ON SCHEMA public TO ${SERVICE_DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${SERVICE_DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${SERVICE_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${SERVICE_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${SERVICE_DB_USER};
EOF

# =============================================================================
# VERIFY DATABASE CREATION
# =============================================================================

log_info "Verifying database creation..."

# Check if database exists
DB_EXISTS=$(kubectl -n "$DB_NAMESPACE" exec -i "$PG_POD" -- psql -U "$ADMIN_USER" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${SERVICE_DB_NAME}'" 2>/dev/null || echo "")

if [ "$DB_EXISTS" = "1" ]; then
    log_success "Database '${SERVICE_DB_NAME}' created successfully"
else
    log_error "Database '${SERVICE_DB_NAME}' creation verification failed"
    exit 1
fi

# Check if user exists
USER_EXISTS=$(kubectl -n "$DB_NAMESPACE" exec -i "$PG_POD" -- psql -U "$ADMIN_USER" -d postgres -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='${SERVICE_DB_USER}'" 2>/dev/null || echo "")

if [ "$USER_EXISTS" = "1" ]; then
    log_success "User '${SERVICE_DB_USER}' created successfully"
else
    log_error "User '${SERVICE_DB_USER}' creation verification failed"
    exit 1
fi

# =============================================================================
# OUTPUT CONNECTION STRING
# =============================================================================

PG_HOST="postgresql.${DB_NAMESPACE}.svc.cluster.local"
PG_PORT="5432"
CONNECTION_STRING="postgresql://${SERVICE_DB_USER}:${POSTGRES_PASSWORD}@${PG_HOST}:${PG_PORT}/${SERVICE_DB_NAME}?sslmode=disable"

log_section "Database Setup Complete"
echo ""
echo "Database Details:"
echo "  Database: ${SERVICE_DB_NAME}"
echo "  User: ${SERVICE_DB_USER}"
echo "  Host: ${PG_HOST}"
echo "  Port: ${PG_PORT}"
echo ""
echo "Connection String (for Kubernetes secrets):"
echo "  ${CONNECTION_STRING}"
echo ""
echo "To create a Kubernetes secret:"
echo "  kubectl create secret generic ${APP_NAME:-${SERVICE_DB_NAME}}-db-secret \\"
echo "    -n ${NAMESPACE} \\"
echo "    --from-literal=DATABASE_URL=\"${CONNECTION_STRING}\""
echo ""

log_success "Service database '${SERVICE_DB_NAME}' is ready for use"
