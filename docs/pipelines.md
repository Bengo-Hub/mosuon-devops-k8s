# CI/CD Pipeline Architecture

Complete guide to the Mosuon cluster deployment pipeline using GitOps with ArgoCD.

## Pipeline Overview

```mermaid
graph LR
    A[Developer] -->|1. Code Push| B[Git Repository]
    B -->|2. Trigger| C[build.sh]
    C -->|3. Build| D[Docker Image]
    C -->|4. Scan| E[Trivy Security]
    D -->|5. Push| F[Docker Hub]
    C -->|6. Update| G[Helm Values]
    G -->|7. Git Push| H[mosuon-devops-k8s]
    H -->|8. Watch| I[ArgoCD]
    I -->|9. Sync| J[Kubernetes]
    J -->|10. Pull| F
    J -->|11. Deploy| K[Pods]
```

## Pipeline Stages

### Stage 1: Local Development

**Location**: Developer workstation
**Tools**: Git, Docker, IDE

```bash
# 1. Make code changes
vim src/main.go

# 2. Test locally
go test ./...

# 3. Commit changes
git add .
git commit -m "feat: add new endpoint"
git push origin main
```

### Stage 2: Build Trigger

**Location**: CI/CD runner or local machine
**Tool**: build.sh script

```bash
# Manual trigger
./build.sh

# GitHub Actions trigger
# - Automatic on push to main
# - Uses secrets for credentials
```

### Stage 3: Security Scanning

**Tool**: Trivy
**Scope**: Filesystem and Docker image

```bash
# Scan for vulnerabilities
trivy fs . --exit-code 0 --format table

# Critical vulnerabilities fail build in production
# Warnings allowed in development (TRIVY_ECODE=0)
```

**Exit Codes**:
- `0`: Allow build to continue (warnings only)
- `1`: Fail build on critical vulnerabilities

### Stage 4: Docker Build

**Tool**: Docker BuildKit
**Registry**: Docker Hub (docker.io/codevertex/*)

```bash
# Build with commit hash tag
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
DOCKER_BUILDKIT=1 docker build . -t "docker.io/codevertex/app:${GIT_COMMIT_ID}"

# Build args for frontend
docker build . \
  --build-arg NEXT_PUBLIC_API_URL=https://api.stats.mosuon.com \
  -t "docker.io/codevertex/game-stats-ui:${GIT_COMMIT_ID}"
```

**Tagging Strategy**:
- Production: Git commit hash (e.g., `abc12345`)
- Development: `latest` + commit hash
- Never use `latest` in production

### Stage 5: Registry Push

**Tool**: Docker CLI
**Authentication**: Registry credentials from secrets

```bash
# Login to Docker Hub
echo "$REGISTRY_PASSWORD" | docker login docker.io \
  -u "$REGISTRY_USERNAME" --password-stdin

# Push image
docker push "docker.io/codevertex/app:${GIT_COMMIT_ID}"
```

### Stage 6: Database Setup (Backend Only)

**Tool**: PostgreSQL psql
**Idempotency**: DO blocks with IF NOT EXISTS

```bash
# Create database idempotently
kubectl exec -n infra postgresql-0 -- psql -U postgres <<'EOF'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'game_stats') THEN
    CREATE DATABASE game_stats;
  END IF;
END $$;
EOF

# Create user and grant permissions
kubectl exec -n infra postgresql-0 -- psql -U postgres <<'EOF'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'game_stats_user') THEN
    CREATE USER game_stats_user WITH PASSWORD 'password';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE game_stats TO game_stats_user;
EOF
```

### Stage 7: Secret Creation

**Tool**: kubectl
**Strategy**: dry-run + apply for idempotency

```bash
# Create secrets only if they don't exist
kubectl -n mosuon create secret generic app-secrets \
  --from-literal=DATABASE_URL="postgresql://user:pass@host:5432/db" \
  --from-literal=JWT_SECRET="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Stage 8: Helm Values Update

**Tool**: yq (YAML processor)
**Location**: mosuon-devops-k8s repository

```bash
# Clone devops repo
git clone https://github.com/Bengo-Hub/mosuon-devops-k8s.git

# Update image tag
yq eval ".image.tag = \"${IMAGE_TAG}\"" -i apps/${APP_NAME}/values.yaml

# Commit and push
git add apps/${APP_NAME}/values.yaml
git commit -m "chore(${APP_NAME}): update image tag to ${IMAGE_TAG}"
git push origin main
```

**File Modified**: `apps/your-app/values.yaml`
```yaml
image:
  repository: docker.io/codevertex/your-app
  tag: abc12345  # ← Updated by pipeline
```

### Stage 9: ArgoCD Sync

**Tool**: ArgoCD
**Mode**: Automated sync with prune and self-heal

```yaml
syncPolicy:
  automated:
    prune: true      # Delete removed resources
    selfHeal: true   # Revert manual changes
  syncOptions:
    - CreateNamespace=true
```

**Process**:
1. ArgoCD detects Git repository change
2. Compares desired state (Git) vs actual state (Kubernetes)
3. Applies changes to cluster
4. Monitors for drift and self-heals

**Sync Interval**: 3 minutes (default)

### Stage 10: Kubernetes Deployment

**Tool**: Kubernetes API
**Resources**: Deployment, Service, Ingress, HPA, Secrets

```bash
# ArgoCD creates/updates these resources:
- Deployment (pods, containers, env vars)
- Service (ClusterIP, port mappings)
- Ingress (NGINX, TLS, domain routing)
- HPA (autoscaling based on CPU/memory)
- Secrets (if using sealed-secrets)
```

**Deployment Strategy**: RollingUpdate
```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```

### Stage 11: Health Checks

**Tool**: Kubernetes probes

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 4000
  initialDelaySeconds: 30
  periodSeconds: 10
  
readinessProbe:
  httpGet:
    path: /health
    port: 4000
  initialDelaySeconds: 5
  periodSeconds: 5
```

**States**:
- **Pending**: Image pull in progress
- **Running**: Container started, waiting for readiness
- **Ready**: Health checks passing, receiving traffic

## Pipeline Variants

### Manual Pipeline (Local Build)

```bash
# Developer runs build.sh manually
./build.sh

# Requires:
# - Docker daemon running
# - kubectl configured with cluster access
# - Git credentials for mosuon-devops-k8s
```

### GitHub Actions Pipeline (Automated)

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Build and Deploy
        env:
          REGISTRY_USERNAME: ${{ secrets.REGISTRY_USERNAME }}
          REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
          KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
          POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
          JWT_SECRET: ${{ secrets.JWT_SECRET }}
          GH_PAT: ${{ secrets.GH_PAT }}
        run: ./build.sh
```

## Monitoring & Observability

### Build Logs

```bash
# GitHub Actions logs
https://github.com/your-org/your-repo/actions

# Local build logs
./build.sh 2>&1 | tee build.log
```

### ArgoCD Dashboard

```bash
# Access ArgoCD UI
https://argocd.ultimatestats.co.ke

# CLI status
kubectl get app -n argocd
```

### Application Logs

```bash
# Pod logs
kubectl logs -n mosuon -l app=your-app --tail=100 -f

# Previous pod logs (for crashed containers)
kubectl logs -n mosuon pod-name --previous
```

### Metrics

```bash
# Prometheus metrics
https://grafana.ultimatestats.co.ke

# Application metrics endpoint
curl https://api.stats.ultimatestats.co.ke/metrics
```

## Rollback Procedures

### Automatic Rollback (ArgoCD)

```bash
# ArgoCD auto-syncs to Git state
# To rollback: revert Git commit and push

git revert HEAD
git push origin main
# ArgoCD detects change and rolls back
```

### Manual Rollback

```bash
# Scale down to zero
kubectl scale deployment your-app -n mosuon --replicas=0

# Update values.yaml to previous image tag
yq eval ".image.tag = \"previous-tag\"" -i apps/your-app/values.yaml

# Commit and push
git add apps/your-app/values.yaml
git commit -m "rollback: revert to previous-tag"
git push origin main

# ArgoCD syncs and redeploys
```

### Emergency Rollback (Kubectl)

```bash
# Rollback last deployment
kubectl rollout undo deployment/your-app -n mosuon

# Rollback to specific revision
kubectl rollout undo deployment/your-app -n mosuon --to-revision=3

# Check rollout history
kubectl rollout history deployment/your-app -n mosuon
```

## Performance Optimization

### Build Cache

```bash
# Use Docker BuildKit caching
DOCKER_BUILDKIT=1 docker build . \
  --cache-from docker.io/codevertex/app:latest \
  -t docker.io/codevertex/app:new-tag
```

### Parallel Builds

```yaml
# GitHub Actions matrix builds
strategy:
  matrix:
    service: [api, ui, worker]
```

### Image Layer Optimization

```dockerfile
# Multi-stage builds to reduce image size
FROM golang:1.22 AS builder
WORKDIR /app
COPY go.* ./
RUN go mod download
COPY . .
RUN go build -o main

FROM alpine:3.19
COPY --from=builder /app/main /main
CMD ["/main"]
```

## Security Best Practices

1. **Secrets**: Never commit to Git, use Kubernetes Secrets
2. **Image Scanning**: Trivy scans for vulnerabilities
3. **Registry Auth**: Pull images from authenticated registry
4. **RBAC**: Limit ArgoCD and pipeline permissions
5. **TLS**: All ingress traffic uses cert-manager TLS
6. **Network Policies**: Restrict pod-to-pod communication
7. **Pod Security**: Run as non-root user

## Failure Scenarios

### Build Fails

```bash
# Check build.sh output
cat build.log

# Common issues:
# - Docker daemon not running
# - Insufficient disk space
# - Dependency download failures
```

### Push Fails

```bash
# Check registry credentials
docker login docker.io

# Check network connectivity
curl https://registry.hub.docker.com/v2/
```

### Sync Fails

```bash
# Check ArgoCD app status
kubectl describe app your-app -n argocd

# Check pod events
kubectl describe pod -n mosuon -l app=your-app

# Force sync
kubectl patch app your-app -n argocd \
  --type merge -p '{"operation":{"sync":{}}}'
```

## Pipeline Metrics

Track these KPIs:
- **Build Time**: Target < 5 minutes
- **Deploy Time**: Target < 2 minutes
- **Success Rate**: Target > 95%
- **MTTR**: Target < 30 minutes
- **Deployment Frequency**: Daily or more

## Future Improvements

- [ ] Blue-green deployments
- [ ] Canary releases with Argo Rollouts
- [ ] Automated integration tests
- [ ] Performance benchmarking
- [ ] Cost optimization reporting
