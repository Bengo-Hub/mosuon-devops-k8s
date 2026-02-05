# Cluster Setup Workflow Guide

Complete step-by-step workflow for setting up the Mosuon Kubernetes cluster from scratch.

## Overview

This guide walks through the entire cluster provisioning process, from bare VPS to production-ready Kubernetes cluster running game-stats applications.

**Estimated Time**: 30-45 minutes
**Target**: 207.180.237.35 (Mosuon Production VPS)

## Architecture Components

```
┌─────────────────────────────────────────────────────────────┐
│  VPS: 207.180.237.35                                        │
│  ├── K3s (Lightweight Kubernetes)                           │
│  ├── NGINX Ingress (HTTP/HTTPS routing)                     │
│  ├── cert-manager (TLS certificates)                        │
│  ├── ArgoCD (GitOps deployment)                             │
│  ├── PostgreSQL (Persistent data)                           │
│  ├── Redis (Caching)                                        │
│  └── Prometheus + Grafana (Monitoring)                      │
└─────────────────────────────────────────────────────────────┘
```

## Pre-Workflow Checklist

### System Requirements

- **VPS**: 4GB+ RAM, 40GB+ storage, Ubuntu 22.04
- **Network**: Public IP, ports 80/443/6443 open
- **Domain**: DNS access for ultimatestats.co.ke

### Required Tools (Local Machine)

```bash
# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install yq
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq
sudo chmod +x /usr/bin/yq

# Install argocd CLI
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64

# Verify installations
kubectl version --client
helm version
yq --version
argocd version --client
```

### Required Credentials

```bash
# GitHub Personal Access Token
export GH_PAT="ghp_xxxxxxxxxxxx"

# Docker Hub credentials
export REGISTRY_USERNAME="your-dockerhub-username"
export REGISTRY_PASSWORD="dckr_pat_xxxxxxxxxxxx"

# PostgreSQL master password (generate strong password)
export POSTGRES_PASSWORD="$(openssl rand -base64 32)"
echo "Save this password: $POSTGRES_PASSWORD"

# JWT secret for API authentication
export JWT_SECRET="$(openssl rand -base64 32)"
echo "Save this JWT secret: $JWT_SECRET"
```

## Workflow Steps

### Phase 1: VPS Preparation (5 minutes)

#### 1.1 Connect to VPS

```bash
# SSH into server
ssh root@207.180.237.35

# Update system
apt-get update && apt-get upgrade -y

# Install prerequisites
apt-get install -y curl wget git openssl
```

#### 1.2 Install K3s

```bash
# Install K3s (lightweight Kubernetes)
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable servicelb \
  --node-label role=worker

# Verify installation
kubectl get nodes

# Should show:
# NAME     STATUS   ROLES                  AGE   VERSION
# host     Ready    control-plane,master   30s   v1.28.x+k3s1
```

#### 1.3 Configure Firewall

```bash
# Allow necessary ports
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS
ufw allow 6443/tcp  # Kubernetes API
ufw allow 22/tcp    # SSH
ufw enable

# Verify
ufw status
```

### Phase 2: Local kubeconfig Setup (3 minutes)

#### 2.1 Get kubeconfig from VPS

```bash
# On VPS, copy kubeconfig content
cat /etc/rancher/k3s/k3s.yaml

# On local machine, save to file
scp root@207.180.237.35:/etc/rancher/k3s/k3s.yaml ~/.kube/mosuon-config

# Update server address
sed -i 's/127.0.0.1/207.180.237.35/' ~/.kube/mosuon-config

# Set as active kubeconfig
export KUBECONFIG=~/.kube/mosuon-config

# Test connection
kubectl get nodes
```

#### 2.2 Create GitHub Secret

```bash
# Base64 encode kubeconfig
cat ~/.kube/mosuon-config | base64 -w 0 > kubeconfig.b64

# Add to GitHub repository secrets as KUBE_CONFIG
# Go to: Settings → Secrets and variables → Actions → New repository secret
# Name: KUBE_CONFIG
# Value: [paste content from kubeconfig.b64]
```

### Phase 3: GitHub Secrets Configuration (5 minutes)

Navigate to the `mosuon-devops-k8s` repository on GitHub:
Settings → Secrets and variables → Actions → New repository secret

Add the following secrets:

| Secret Name | Description | Example Value |
|------------|-------------|---------------|
| `KUBE_CONFIG` | Base64-encoded kubeconfig | `LS0tLS1CRUd...` |
| `POSTGRES_PASSWORD` | PostgreSQL master password | `Xk9P2mN...` |
| `REGISTRY_USERNAME` | Docker Hub username | `codevertex` |
| `REGISTRY_PASSWORD` | Docker Hub access token | `dckr_pat_...` |
| `SSH_HOST` | VPS IP address | `207.180.237.35` |
| `GH_PAT` | GitHub Personal Access Token | `ghp_...` |
| `JWT_SECRET` | JWT signing secret | `aB3Cd4...` |

### Phase 4: Run Provisioning Workflow (15 minutes)

#### 4.1 Trigger GitHub Actions Workflow

```bash
# Clone mosuon-devops-k8s repository
git clone https://github.com/Bengo-Hub/mosuon-devops-k8s.git
cd mosuon-devops-k8s

# Trigger provision workflow
gh workflow run provision.yml

# Or manually via GitHub UI:
# Actions → Provision Infrastructure → Run workflow

# Monitor progress
gh run watch
```

#### 4.2 What the Workflow Does

The `provision.yml` workflow automatically:

1. **Install DevOps Tools**
   - kubectl (Kubernetes CLI)
   - helm (Package manager)
   - yq (YAML processor)
   - argocd (GitOps CLI)

2. **Create Namespaces**
   ```bash
   - infra    # Infrastructure services
   - argocd   # GitOps controller
   - mosuon   # Application workloads
   ```

3. **Setup Registry Credentials**
   - Creates Docker pull secrets in all namespaces

4. **Install Storage Provisioner**
   - Rancher local-path-provisioner for dynamic PVCs

5. **Install NGINX Ingress**
   - NodePort on 30080 (HTTP) and 30443 (HTTPS)
   - External traffic routing

6. **Install cert-manager**
   - Automatic TLS certificate management
   - Let's Encrypt integration

7. **Deploy PostgreSQL**
   - 20Gi persistent storage
   - Bitnami Helm chart
   - Root password from secrets

8. **Deploy Redis**
   - 8Gi persistent storage
   - Bitnami Helm chart
   - Authentication enabled

9. **Create Application Database**
   - `game_stats` database
   - `game_stats_user` with permissions

10. **Create Application Secrets**
    - DATABASE_URL
    - REDIS_PASSWORD
    - JWT_SECRET

11. **Install Argo CD**
    - GitOps deployment controller
    - Ingress at argocd.ultimatestats.co.ke

12. **Bootstrap Applications**
    - root-app (app-of-apps)
    - game-stats-api
    - game-stats-ui

#### 4.3 Monitor Workflow Progress

```bash
# Watch workflow run
gh run watch

# Or view logs in GitHub Actions UI
# https://github.com/Bengo-Hub/mosuon-devops-k8s/actions
```

Expected output stages:
```
✓ Install DevOps Tools
✓ Setup Kubernetes Access
✓ Create Namespaces
✓ Create Registry Secrets
✓ Install Storage Provisioner
✓ Install NGINX Ingress
✓ Install cert-manager
✓ Deploy PostgreSQL
✓ Deploy Redis
✓ Create Database and User
✓ Create Application Secrets
✓ Install Argo CD
✓ Bootstrap ArgoCD Applications
```

### Phase 5: DNS Configuration (5 minutes)

#### 5.1 Configure DNS Records

Login to your DNS provider and add these A records:

```
Type   Name                          Value           TTL
────────────────────────────────────────────────────────
A      stats.ultimatestats.co.ke     207.180.237.35  300
A      api.stats.ultimatestats.co.ke 207.180.237.35  300
A      argocd.ultimatestats.co.ke    207.180.237.35  300
A      grafana.ultimatestats.co.ke   207.180.237.35  300
A      superset.ultimatestats.co.ke  207.180.237.35  300
```

#### 5.2 Verify DNS Propagation

```bash
# Check DNS resolution
nslookup stats.ultimatestats.co.ke
nslookup api.stats.ultimatestats.co.ke
nslookup argocd.ultimatestats.co.ke

# Or use dig
dig stats.ultimatestats.co.ke +short
# Should return: 207.180.237.35
```

Wait 5-10 minutes for global DNS propagation.

### Phase 6: Deploy Applications (5 minutes)

#### 6.1 Build and Deploy API

```bash
cd game-stats/game-stats-api

# Export required environment variables
export REGISTRY_USERNAME="codevertex"
export REGISTRY_PASSWORD="dckr_pat_xxxx"
export KUBE_CONFIG="$(cat ~/.kube/mosuon-config | base64 -w 0)"
export POSTGRES_PASSWORD="your-postgres-password"
export GH_PAT="ghp_xxxx"
export JWT_SECRET="your-jwt-secret"

# Run build script
chmod +x build.sh
./build.sh
```

Build process:
1. Trivy security scan
2. Docker image build
3. Push to docker.io/codevertex/game-stats-api
4. Create Kubernetes secrets
5. Update Helm values in Git
6. ArgoCD auto-syncs deployment

#### 6.2 Build and Deploy UI

```bash
cd game-stats/game-stats-ui

# Same environment variables as API
./build.sh
```

Build process:
1. Trivy security scan
2. Next.js Docker image build
3. Push to docker.io/codevertex/game-stats-ui
4. Update Helm values in Git
5. ArgoCD auto-syncs deployment

### Phase 7: Verification (5 minutes)

#### 7.1 Check Cluster Health

```bash
# Check all nodes
kubectl get nodes

# Check all pods
kubectl get pods -A

# Expected output:
# NAMESPACE   NAME                           READY   STATUS
# infra       postgresql-0                   1/1     Running
# infra       redis-master-0                 1/1     Running
# argocd      argocd-server-xxx              1/1     Running
# mosuon      game-stats-api-xxx             1/1     Running
# mosuon      game-stats-ui-xxx              1/1     Running
```

#### 7.2 Check ArgoCD Applications

```bash
# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo

# Login to ArgoCD
argocd login argocd.ultimatestats.co.ke
# Username: admin
# Password: [from above]

# List applications
argocd app list

# Expected output:
# NAME              CLUSTER                         NAMESPACE  PROJECT  STATUS  HEALTH
# root-app          https://kubernetes.default.svc  argocd     default  Synced  Healthy
# game-stats-api    https://kubernetes.default.svc  mosuon     default  Synced  Healthy
# game-stats-ui     https://kubernetes.default.svc  mosuon     default  Synced  Healthy
```

#### 7.3 Check Ingress

```bash
# Check ingress resources
kubectl get ingress -n mosuon

# Should show:
# NAME              HOSTS                          ADDRESS          PORTS
# game-stats-api    api.stats.ultimatestats.co.ke  207.180.237.35   80, 443
# game-stats-ui     stats.ultimatestats.co.ke      207.180.237.35   80, 443
```

#### 7.4 Check TLS Certificates

```bash
# Check certificate status
kubectl get certificate -n mosuon

# Should show Ready=True:
# NAME                 READY   SECRET               AGE
# game-stats-api-tls   True    game-stats-api-tls   5m
# game-stats-ui-tls    True    game-stats-ui-tls    5m

# If not ready, check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager
```

#### 7.5 Test Application Endpoints

```bash
# Test API health
curl https://api.stats.ultimatestats.co.ke/health
# Expected: {"status":"ok","timestamp":"..."}

# Test UI
curl -I https://stats.ultimatestats.co.ke
# Expected: HTTP/2 200

# Open in browser
open https://stats.ultimatestats.co.ke
open https://api.stats.ultimatestats.co.ke/health
```

#### 7.6 Check Database Connection

```bash
# Test PostgreSQL connection
kubectl exec -it -n infra postgresql-0 -- psql -U postgres -d game_stats -c "SELECT version();"

# List tables
kubectl exec -it -n infra postgresql-0 -- psql -U postgres -d game_stats -c "\dt"
```

## Post-Setup Tasks

### 1. Secure ArgoCD Admin Password

```bash
# Change default password
argocd account update-password

# Or create additional users
kubectl -n argocd edit configmap argocd-cm
# Add users under data.accounts.<username>
```

### 2. Configure Monitoring

```bash
# Install Prometheus + Grafana (if not already installed)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace infra \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.hosts[0]=grafana.ultimatestats.co.ke
```

### 3. Setup Backups

```bash
# Create backup script
cat > /root/backup.sh <<'EOF'
#!/bin/bash
BACKUP_DIR="/root/backups"
DATE=$(date +%Y%m%d_%H%M%S)

# Backup PostgreSQL
kubectl exec -n infra postgresql-0 -- pg_dumpall -U postgres | gzip > $BACKUP_DIR/postgres_$DATE.sql.gz

# Backup Kubernetes manifests
kubectl get all -A -o yaml > $BACKUP_DIR/k8s_$DATE.yaml

# Keep only last 7 days
find $BACKUP_DIR -type f -mtime +7 -delete
EOF

chmod +x /root/backup.sh

# Add to crontab (daily at 2 AM)
(crontab -l 2>/dev/null; echo "0 2 * * * /root/backup.sh") | crontab -
```

### 4. Configure Log Rotation

```bash
# Install Loki for log aggregation (optional)
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack \
  --namespace infra \
  --set promtail.enabled=true
```

### 5. Enable Network Policies

```bash
# Apply default deny policy
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: mosuon
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: mosuon
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
EOF
```

## Troubleshooting

### Workflow Fails

```bash
# Check workflow logs in GitHub Actions
# Common issues:
# 1. Invalid KUBE_CONFIG secret
# 2. Missing GitHub secrets
# 3. Network connectivity issues
# 4. Insufficient cluster resources
```

### Pods Not Starting

```bash
# Check pod status
kubectl describe pod <pod-name> -n mosuon

# Common issues:
# 1. Image pull errors → Check registry credentials
# 2. CrashLoopBackOff → Check application logs
# 3. Pending → Check resource availability
```

### Database Connection Issues

```bash
# Verify PostgreSQL is running
kubectl get pods -n infra -l app=postgresql

# Test connection
kubectl exec -it -n infra postgresql-0 -- psql -U postgres -c "\l"

# Check secrets
kubectl get secret game-stats-api-secrets -n mosuon -o yaml
```

### TLS Certificate Not Issuing

```bash
# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Check certificate status
kubectl describe certificate game-stats-api-tls -n mosuon

# Common issues:
# 1. DNS not propagated → Wait 10-15 minutes
# 2. Rate limit → Use staging Let's Encrypt
# 3. Firewall blocking port 80 → Check ufw rules
```

## Rollback Procedures

### Rollback Application

```bash
# Via ArgoCD
argocd app rollback game-stats-api

# Via kubectl
kubectl rollout undo deployment/game-stats-api -n mosuon
```

### Restore Database

```bash
# From backup
gunzip -c backup.sql.gz | kubectl exec -i -n infra postgresql-0 -- psql -U postgres
```

### Reinstall Infrastructure Component

```bash
# Example: Reinstall NGINX Ingress
helm uninstall ingress-nginx -n ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace
```

## Success Criteria

Cluster setup is complete when:

- [ ] All pods are in Running state
- [ ] ArgoCD applications are Synced and Healthy
- [ ] TLS certificates are Ready
- [ ] All endpoints return 200 OK
- [ ] Database connections successful
- [ ] Monitoring dashboards accessible
- [ ] Backups configured and tested

## Next Steps

1. Read [Operations Runbook](OPERATIONS-RUNBOOK.md)
2. Configure [Monitoring](monitoring.md)
3. Setup [Scaling policies](scaling.md)
4. Review [Security best practices](comprehensive-access-setup.md)
