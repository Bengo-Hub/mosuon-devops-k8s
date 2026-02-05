# Fast-Track Setup Guide

Complete deployment of the Mosuon Kubernetes cluster in under 30 minutes.

## Prerequisites Checklist

Before starting, ensure you have:

- [ ] Ubuntu 22.04 VPS at 207.180.237.35 with root access
- [ ] Docker Hub account (username/password)
- [ ] GitHub account with repository access
- [ ] Domain ultimatestats.co.ke with DNS management access
- [ ] Local machine with Git, Docker, kubectl, and helm installed

## Step 1: Access Configuration (5 minutes)

### 1.1 SSH Access

```bash
# Test SSH connection
ssh root@207.180.237.35

# If successful, add to ~/.ssh/config
cat >> ~/.ssh/config <<EOF
Host mosuon-prod
    HostName 207.180.237.35
    User root
    IdentityFile ~/.ssh/id_rsa
EOF
```

### 1.2 GitHub Personal Access Token

Create a GitHub PAT with permissions:
- `repo` (full access)
- `workflow` (update workflows)
- `read:packages` (read container registry)

```bash
# Save to environment
export GH_PAT="ghp_your_token_here"
```

## Step 2: Cluster Provisioning (15 minutes)

### 2.1 Configure GitHub Secrets

In the `mosuon-devops-k8s` repository settings:

```bash
# Navigate to Settings → Secrets → Actions → New repository secret

# Add these secrets:
KUBE_CONFIG           # Generated in step 2.2
POSTGRES_PASSWORD     # Strong password for PostgreSQL
REGISTRY_USERNAME     # Docker Hub username
REGISTRY_PASSWORD     # Docker Hub password/token
SSH_HOST             # 207.180.237.35
GH_PAT               # GitHub Personal Access Token
JWT_SECRET           # openssl rand -base64 32
```

### 2.2 Generate kubeconfig

SSH into the VPS and install K3s:

```bash
ssh root@207.180.237.35

# Install K3s
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable servicelb

# Get kubeconfig
cat /etc/rancher/k3s/k3s.yaml

# On your local machine, encode it
cat k3s.yaml | base64 -w 0 > kubeconfig.b64
# Add the base64 content to KUBE_CONFIG secret
```

### 2.3 Run Provisioning Workflow

```bash
# In mosuon-devops-k8s repository
gh workflow run provision.yml

# Monitor progress
gh run watch
```

This installs:
- PostgreSQL (20Gi storage)
- Redis (8Gi storage)
- NGINX Ingress Controller
- cert-manager for TLS
- Argo CD for GitOps
- Prometheus + Grafana (optional)

## Step 3: DNS Configuration (5 minutes)

Add A records to your DNS provider:

```
stats.ultimatestats.co.ke        A    207.180.237.35
api.stats.ultimatestats.co.ke    A    207.180.237.35
argocd.ultimatestats.co.ke       A    207.180.237.35
grafana.ultimatestats.co.ke      A    207.180.237.35
superset.ultimatestats.co.ke     A    207.180.237.35
```

Wait 5-10 minutes for DNS propagation.

## Step 4: Deploy Applications (5 minutes)

### 4.1 Build and Deploy API

```bash
cd game-stats/game-stats-api

# Set environment variables
export REGISTRY_USERNAME="your-docker-username"
export REGISTRY_PASSWORD="your-docker-password"
export KUBE_CONFIG="$(cat ~/.kube/config | base64 -w 0)"
export POSTGRES_PASSWORD="your-postgres-password"
export GH_PAT="your-github-token"

# Build and deploy
./build.sh
```

### 4.2 Build and Deploy UI

```bash
cd game-stats/game-stats-ui

# Same environment variables as above
./build.sh
```

## Step 5: Verification (3 minutes)

### 5.1 Check ArgoCD

```bash
# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Login to ArgoCD UI
open https://argocd.ultimatestats.co.ke
# Username: admin
# Password: (from above command)
```

### 5.2 Check Applications

```bash
# Check all pods are running
kubectl get pods -n mosuon
kubectl get pods -n infra
kubectl get pods -n argocd

# Check ingress
kubectl get ingress -n mosuon

# Test API health
curl https://api.stats.ultimatestats.co.ke/health

# Visit UI
open https://stats.ultimatestats.co.ke
```

### 5.3 Check TLS Certificates

```bash
# Check certificate status
kubectl get certificate -n mosuon

# Should show Ready=True for:
# - game-stats-api-tls
# - game-stats-ui-tls
```

## Step 6: Monitoring Setup (Optional)

### 6.1 Access Grafana

```bash
# Get Grafana password
kubectl get secret -n infra grafana-admin-credentials \
  -o jsonpath="{.data.admin-password}" | base64 -d

# Login
open https://grafana.ultimatestats.co.ke
```

### 6.2 Configure Dashboards

1. Add Prometheus data source: `http://prometheus-server.infra:9090`
2. Import dashboards:
   - Kubernetes Cluster Monitoring (ID: 7249)
   - PostgreSQL Database (ID: 9628)
   - NGINX Ingress Controller (ID: 9614)

## Troubleshooting

### Pods stuck in Pending

```bash
# Check events
kubectl get events -n mosuon --sort-by='.lastTimestamp'

# Common issue: Insufficient resources
kubectl describe node
```

### Image pull errors

```bash
# Verify registry secret
kubectl get secret registry-credentials -n mosuon -o yaml

# Recreate if needed
kubectl delete secret registry-credentials -n mosuon
kubectl create secret docker-registry registry-credentials \
  --docker-server=docker.io \
  --docker-username=$REGISTRY_USERNAME \
  --docker-password=$REGISTRY_PASSWORD \
  -n mosuon
```

### Certificate not issuing

```bash
# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Check certificate status
kubectl describe certificate game-stats-api-tls -n mosuon

# Common issue: DNS not propagated yet - wait 10 minutes
```

### Database connection errors

```bash
# Check PostgreSQL is running
kubectl get pods -n infra -l app=postgresql

# Test connection from pod
kubectl run -it --rm debug --image=postgres:15 --restart=Never -- \
  psql "postgresql://game_stats_user:$POSTGRES_PASSWORD@postgresql.infra:5432/game_stats"
```

## Next Steps

1. **Read Documentation**:
   - [Comprehensive Access Setup](docs/comprehensive-access-setup.md)
   - [Operations Runbook](docs/OPERATIONS-RUNBOOK.md)
   - [Monitoring Guide](docs/monitoring.md)

2. **Setup CI/CD**:
   - Configure GitHub Actions for automated builds
   - See [docs/pipelines.md](docs/pipelines.md)

3. **Secure Cluster**:
   - Rotate default passwords
   - Setup backup procedures
   - Configure network policies

4. **Scale Applications**:
   - Adjust HPA settings
   - Enable VPA for resource optimization
   - See [docs/scaling.md](docs/scaling.md)

## Support

- **Issues**: [GitHub Issues](https://github.com/Bengo-Hub/mosuon-devops-k8s/issues)
- **Documentation**: [docs/](docs/)
- **DevOps Team**: Contact via Slack #devops channel
