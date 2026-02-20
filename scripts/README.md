# Mosuon DevOps Scripts

This directory contains reusable infrastructure and deployment scripts for the Mosuon Kubernetes cluster.

## Directory Structure

```
scripts/
├── infrastructure/           # Cluster and service infrastructure
│   ├── configure-ingress-controller.sh
│   ├── create-service-database.sh
│   ├── create-service-secrets.sh
│   ├── install-argocd.sh
│   ├── install-cert-manager.sh
│   ├── install-databases.sh
│   └── install-storage-provisioner.sh
├── helm/                     # Helm chart management
│   └── update-values.sh
└── tools/                    # Shared utilities
    └── common.sh
```

## Infrastructure Scripts

### cluster/setup-*.sh
Idempotent kubeadm-based cluster orchestrator (VPS → containerd → kubeadm → CNI). Useful for single-node or small VPS clusters.

Usage (on VPS):

```bash
cd /opt/mosuon-devops-k8s
chmod +x scripts/cluster/*.sh
./scripts/cluster/setup-cluster.sh
```

### run-remote-setup.sh
Local helper that SSHs into the VPS, clones `mosuon-devops-k8s` under `/opt` and runs the cluster orchestrator. Example:

```bash
./scripts/infrastructure/run-remote-setup.sh root@207.180.237.35
```

### install-storage-provisioner.sh
Installs Rancher local-path-provisioner for dynamic PVC provisioning.

```bash
./scripts/infrastructure/install-storage-provisioner.sh
```

### configure-ingress-controller.sh
Installs and configures NGINX Ingress Controller.

```bash
# Default NodePort configuration
./scripts/infrastructure/configure-ingress-controller.sh

# Custom ports
HTTP_PORT=30080 HTTPS_PORT=30443 ./scripts/infrastructure/configure-ingress-controller.sh
```

### install-cert-manager.sh
Installs cert-manager and creates LetsEncrypt ClusterIssuers.

```bash
ACME_EMAIL=admin@ultichange.org ./scripts/infrastructure/install-cert-manager.sh
```

### install-databases.sh
Installs PostgreSQL and Redis for shared infrastructure.

```bash
POSTGRES_PASSWORD=xxx NAMESPACE=infra ./scripts/infrastructure/install-databases.sh
```

### install-argocd.sh
Installs ArgoCD with production ingress configuration.

```bash
ARGOCD_DOMAIN=argocd.ultichange.org ./scripts/infrastructure/install-argocd.sh
```

### create-service-database.sh
Creates a per-service database on the shared PostgreSQL instance.

```bash
SERVICE_DB_NAME=game_stats \
SERVICE_DB_USER=game_stats_user \
APP_NAME=game-stats-api \
NAMESPACE=mosuon \
./scripts/infrastructure/create-service-database.sh
```

### create-service-secrets.sh
Creates Kubernetes secrets for a service with database connection strings.

```bash
SERVICE_NAME=game-stats-api \
NAMESPACE=mosuon \
DB_NAME=game_stats \
./scripts/infrastructure/create-service-secrets.sh
```

## Helm Scripts

### update-values.sh
Updates Helm values in the devops repository for GitOps deployment.

```bash
# As a function (source the script)
source scripts/helm/update-values.sh
update_helm_values "game-stats-api" "abc12345" "docker.io/codevertex/game-stats-api"

# Direct execution
./scripts/helm/update-values.sh --app game-stats-api --tag abc12345 --repo docker.io/codevertex/game-stats-api
```

## Tools

### common.sh
Shared utility functions for all scripts. Source this file in your scripts:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"
```

**Available functions:**
- `log_info`, `log_success`, `log_warning`, `log_error`, `log_step`, `log_section` - Logging
- `check_kubectl` - Verify kubectl and cluster connectivity
- `ensure_helm` - Install Helm if missing
- `ensure_namespace` - Create namespace if not exists
- `add_helm_repo` - Add and update Helm repository
- `wait_for_pods`, `wait_for_deployment`, `wait_for_statefulset` - Wait helpers
- `wait_for_postgresql` - Wait for PostgreSQL to be ready
- `generate_password` - Generate secure random password
- `get_secret_value` - Retrieve secret value from Kubernetes
- `is_cleanup_mode`, `safe_delete_resource` - Cleanup mode helpers

## Environment Variables

Common environment variables used across scripts:

| Variable | Description | Default |
|----------|-------------|---------|
| `NAMESPACE` | Kubernetes namespace | `mosuon` |
| `DB_NAMESPACE` | Database namespace | `infra` |
| `POSTGRES_PASSWORD` | PostgreSQL password | (required) |
| `ENABLE_CLEANUP` | Delete resources before recreating | `false` |
| `ARGOCD_DOMAIN` | ArgoCD domain | `argocd.ultichange.org` |
| `GRAFANA_DOMAIN` | Grafana domain | `grafana.ultichange.org` |
| `ANALYTICS_DOMAIN` | Analytics (Metabase) domain | `analytics.ultichange.org` |
| `VPS_IP` | VPS IP address | `207.180.237.35` |

Note: This repo does not install RabbitMQ. Mosuon uses Redis and Postgres (with `pgvector`) for caching and embeddings respectively.

## Usage in Build Scripts

Application build scripts (`build.sh`) use these centralized scripts for consistency:

```bash
# In game-stats-api/build.sh
DEVOPS_DIR="$HOME/mosuon-devops-k8s"

# Create database
./scripts/infrastructure/create-service-database.sh

# Create secrets
./scripts/infrastructure/create-service-secrets.sh

# Update Helm values
source "${DEVOPS_DIR}/scripts/helm/update-values.sh"
update_helm_values "$APP_NAME" "$GIT_COMMIT_ID" "$IMAGE_REPO"
```

## Adding New Scripts

1. Create script in appropriate directory
2. Source `../tools/common.sh` for shared functions
3. Use `set -euo pipefail` for error handling
4. Make script idempotent (safe to run multiple times)
5. Document usage in this README
