# Onboarding Guide: Adding Applications to Mosuon Cluster

This guide walks you through deploying a new application to the Mosuon Kubernetes cluster (207.180.237.35) using GitOps with ArgoCD.

## Architecture Overview

```
Developer → build.sh → Docker Hub → Git Push → ArgoCD → Kubernetes
```

1. **Developer** runs `build.sh` in app repository
2. **build.sh** builds Docker image and pushes to Docker Hub
3. **build.sh** updates Helm values in mosuon-devops-k8s repo
4. **Git** commit/push triggers ArgoCD sync
5. **ArgoCD** detects change and deploys to Kubernetes

## Prerequisites

- Access to mosuon-devops-k8s repository
- Docker Hub account (codevertex organization)
- kubectl configured with cluster credentials
- Helm 3.x installed
- yq and jq CLI tools

## Step 1: Prepare Your Application

### 1.1 Create Dockerfile

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./
EXPOSE 3000
CMD ["npm", "start"]
```

### 1.2 Identify Configuration Requirements

Document your app's needs:
- **Port**: 3000, 4000, 8080, etc.
- **Environment Variables**: DATABASE_URL, REDIS_URL, etc.
- **Secrets**: API keys, JWT secrets, passwords
- **Dependencies**: PostgreSQL, Redis, RabbitMQ
- **Resources**: CPU/Memory requirements
- **Health Checks**: /health or /api/health endpoints

## Step 2: Create ArgoCD Application

### 2.1 Create App Directory

```bash
cd mosuon-devops-k8s
mkdir -p apps/your-app-name
```

### 2.2 Create `apps/your-app-name/app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: your-app-name
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Bengo-Hub/mosuon-devops-k8s.git
    path: charts/app
    targetRevision: main
    helm:
      valueFiles:
        - ../../apps/your-app-name/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: mosuon
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 2.3 Create `apps/your-app-name/values.yaml`

```yaml
replicaCount: 1

image:
  repository: docker.io/codevertex/your-app-name
  tag: latest
  pullPolicy: Always

service:
  type: ClusterIP
  port: 3000

env:
  - name: NODE_ENV
    value: "production"
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: your-app-secrets
        key: DATABASE_URL

resources:
  requests:
    memory: "256Mi"
    cpu: "100m"
  limits:
    memory: "512Mi"
    cpu: "500m"

healthCheck:
  enabled: true
  path: /health
  initialDelaySeconds: 30
  periodSeconds: 10

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: your-app.ultimatestats.co.ke
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: your-app-tls
      hosts:
        - your-app.ultimatestats.co.ke

autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 3
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 75
```

## Step 3: Create Database & Secrets

### 3.1 Create PostgreSQL Database (if needed)

```bash
kubectl exec -n infra postgresql-0 -- psql -U postgres -c \
  "CREATE DATABASE your_app;"

kubectl exec -n infra postgresql-0 -- psql -U postgres -c \
  "CREATE USER your_app_user WITH PASSWORD 'secure-password';"

kubectl exec -n infra postgresql-0 -- psql -U postgres -c \
  "GRANT ALL PRIVILEGES ON DATABASE your_app TO your_app_user;"

kubectl exec -n infra postgresql-0 -- psql -U postgres -d your_app -c \
  "GRANT ALL ON SCHEMA public TO your_app_user;"
```

### 3.2 Create Kubernetes Secrets

```bash
kubectl -n mosuon create secret generic your-app-secrets \
  --from-literal=DATABASE_URL="postgresql://your_app_user:password@postgresql.infra:5432/your_app" \
  --from-literal=REDIS_PASSWORD="your-redis-password" \
  --from-literal=JWT_SECRET="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Step 4: Create Build Script

### 4.1 Create `your-app/build.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="your-app-name"
NAMESPACE="mosuon"
IMAGE_REPO="docker.io/codevertex/${APP_NAME}"
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)

# Build Docker image
docker build . -t "${IMAGE_REPO}:${GIT_COMMIT_ID}"

# Push to registry
docker push "${IMAGE_REPO}:${GIT_COMMIT_ID}"

# Update Helm values
export APP_NAME IMAGE_TAG="${GIT_COMMIT_ID}"
bash ../mosuon-devops-k8s/scripts/helm/update-values.sh
```

Make it executable:
```bash
chmod +x build.sh
```

## Step 5: Bootstrap ArgoCD Application

### 5.1 Commit Changes

```bash
cd mosuon-devops-k8s
git add apps/your-app-name/
git commit -m "feat: add your-app-name ArgoCD application"
git push origin main
```

### 5.2 Create Application in ArgoCD

```bash
kubectl apply -f apps/your-app-name/app.yaml
```

### 5.3 Verify Deployment

```bash
# Check ArgoCD app status
kubectl get app -n argocd your-app-name

# Check pods
kubectl get pods -n mosuon -l app=your-app-name

# Check logs
kubectl logs -n mosuon -l app=your-app-name --tail=50
```

## Step 6: Configure DNS & Ingress

### 6.1 Point DNS to Cluster

Add A record:
```
your-app.ultimatestats.co.ke → 207.180.237.35
```

### 6.2 Verify TLS Certificate

```bash
kubectl get certificate -n mosuon your-app-tls
```

## Step 7: Setup CI/CD (Optional)

### 7.1 Create GitHub Actions Workflow

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
          GH_PAT: ${{ secrets.GH_PAT }}
        run: ./build.sh
```

## Troubleshooting

### Application not syncing

```bash
# Force sync
kubectl patch app your-app-name -n argocd \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"syncStrategy":{"hook":{}}}}}'
```

### Check ArgoCD logs

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

### Check pod events

```bash
kubectl describe pod -n mosuon -l app=your-app-name
```

### Database connection issues

```bash
# Test database connectivity
kubectl run -it --rm debug --image=postgres:15 --restart=Never -- \
  psql "postgresql://your_app_user:password@postgresql.infra:5432/your_app"
```

## Best Practices

1. **Secrets Management**: Never commit secrets to Git - use Kubernetes Secrets
2. **Resource Limits**: Always set CPU/memory requests and limits
3. **Health Checks**: Implement /health endpoints for liveness/readiness probes
4. **Migrations**: Use Helm hooks for database migrations
5. **Logging**: Use structured JSON logging for better observability
6. **Metrics**: Expose /metrics endpoint for Prometheus scraping
7. **Graceful Shutdown**: Handle SIGTERM signals properly
8. **Idempotency**: Ensure database/secret creation is idempotent
9. **Versioning**: Tag images with Git commit hash, not "latest"
10. **Documentation**: Update this guide when adding new patterns

## Example Applications

Reference these for patterns:
- **game-stats-api**: Go/Chi/Ent backend with PostgreSQL
- **game-stats-ui**: Next.js 15 PWA frontend

## Support

- **DevOps Issues**: Check [mosuon-devops-k8s/issues](https://github.com/Bengo-Hub/mosuon-devops-k8s/issues)
- **Cluster Access**: Contact DevOps team
- **DNS Changes**: Contact Infrastructure team
