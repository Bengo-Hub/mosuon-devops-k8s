# Comprehensive Access Setup Guide

This guide covers all access requirements for managing the Mosuon Kubernetes cluster infrastructure.

## Table of Contents

1. [SSH Access](#ssh-access)
2. [GitHub Access](#github-access)
3. [Docker Registry Access](#docker-registry-access)
4. [Kubernetes Access](#kubernetes-access)
5. [Database Access](#database-access)
6. [Monitoring Access](#monitoring-access)
7. [Security Best Practices](#security-best-practices)

## SSH Access

### Prerequisites

- SSH client installed (OpenSSH, PuTTY, etc.)
- VPS IP: 207.180.237.35
- Root credentials

### Method 1: Password Authentication (Initial Setup)

```bash
# Connect with password
ssh root@207.180.237.35
# Enter password when prompted
```

### Method 2: SSH Key Authentication (Recommended)

```bash
# Generate SSH key pair (if you don't have one)
ssh-keygen -t ed25519 -C "your-email@example.com"
# Save to ~/.ssh/id_ed25519

# Copy public key to server
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@207.180.237.35

# Test connection (should not prompt for password)
ssh root@207.180.237.35
```

### Configure SSH Config

```bash
# Edit ~/.ssh/config
cat >> ~/.ssh/config <<EOF
Host mosuon-prod
    HostName 207.180.237.35
    User root
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF

# Now connect simply with:
ssh mosuon-prod
```

### Add SSH Host to Known Hosts

```bash
# Remove old host key (if IP was previously used)
ssh-keygen -R 207.180.237.35

# Connect and accept new key
ssh -o StrictHostKeyChecking=accept-new root@207.180.237.35
```

### Disable Password Authentication (After Key Setup)

```bash
# SSH into server
ssh mosuon-prod

# Edit SSH config
sudo nano /etc/ssh/sshd_config

# Set these values:
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password

# Restart SSH service
sudo systemctl restart sshd
```

## GitHub Access

### Personal Access Token (PAT)

Required for:
- Cloning private repositories
- Pushing to repositories
- GitHub Actions workflows
- GitHub Container Registry

#### Create PAT

1. Navigate to https://github.com/settings/tokens
2. Click "Generate new token" → "Generate new token (classic)"
3. Select scopes:
   - `repo` - Full control of private repositories
   - `workflow` - Update GitHub Actions workflows
   - `read:packages` - Read packages from GitHub Container Registry
   - `write:packages` - Write packages to GitHub Container Registry
   - `delete:packages` - Delete packages from GitHub Container Registry (optional)
4. Generate and save the token securely

```bash
# Save to environment
export GH_PAT="ghp_your_token_here"

# Configure Git to use token
git config --global credential.helper store
echo "https://${GH_PAT}@github.com" > ~/.git-credentials
chmod 600 ~/.git-credentials
```

#### Using PAT in Scripts

```bash
# Clone private repository
git clone https://${GH_PAT}@github.com/Bengo-Hub/mosuon-devops-k8s.git

# Or configure as remote
git remote set-url origin https://${GH_PAT}@github.com/Bengo-Hub/mosuon-devops-k8s.git
```

### SSH Keys for GitHub

Alternative to PAT for Git operations:

```bash
# Generate SSH key
ssh-keygen -t ed25519 -C "your-email@example.com" -f ~/.ssh/github_ed25519

# Copy public key
cat ~/.ssh/github_ed25519.pub

# Add to GitHub:
# 1. Go to https://github.com/settings/keys
# 2. Click "New SSH key"
# 3. Paste public key

# Configure SSH config
cat >> ~/.ssh/config <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/github_ed25519
EOF

# Test connection
ssh -T git@github.com
```

## Docker Registry Access

### Docker Hub

Required for pushing/pulling container images.

#### Create Access Token

1. Login to https://hub.docker.com
2. Go to Account Settings → Security
3. Click "New Access Token"
4. Name: "mosuon-cluster"
5. Permissions: Read, Write, Delete
6. Generate and save token

#### Configure Docker CLI

```bash
# Login to Docker Hub
docker login docker.io
# Username: your-docker-username
# Password: [paste access token]

# Verify login
docker info | grep Username

# Save credentials for automation
export REGISTRY_USERNAME="your-docker-username"
export REGISTRY_PASSWORD="dckr_pat_your_token_here"
```

#### Create Kubernetes Registry Secret

```bash
# Create secret in all namespaces
for ns in mosuon infra argocd; do
  kubectl create secret docker-registry registry-credentials \
    --docker-server=docker.io \
    --docker-username=$REGISTRY_USERNAME \
    --docker-password=$REGISTRY_PASSWORD \
    --namespace=$ns \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

## Kubernetes Access

### Install kubectl

```bash
# macOS
brew install kubectl

# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y kubectl

# Windows (PowerShell)
choco install kubernetes-cli

# Verify installation
kubectl version --client
```

### Get kubeconfig from K3s

```bash
# SSH into VPS
ssh mosuon-prod

# K3s kubeconfig location
sudo cat /etc/rancher/k3s/k3s.yaml
```

### Configure Local kubectl

```bash
# Copy kubeconfig to local machine
scp mosuon-prod:/etc/rancher/k3s/k3s.yaml ~/.kube/mosuon-config

# Edit server address
sed -i 's/127.0.0.1/207.180.237.35/' ~/.kube/mosuon-config

# Set KUBECONFIG environment variable
export KUBECONFIG=~/.kube/mosuon-config

# Or merge with existing config
KUBECONFIG=~/.kube/config:~/.kube/mosuon-config kubectl config view --flatten > ~/.kube/config.new
mv ~/.kube/config.new ~/.kube/config
kubectl config use-context default

# Test connection
kubectl get nodes
kubectl get pods -A
```

### Base64 Encode for GitHub Secrets

```bash
# Encode kubeconfig for GitHub Actions
cat ~/.kube/mosuon-config | base64 -w 0 > kubeconfig.b64

# On macOS
cat ~/.kube/mosuon-config | base64 | tr -d '\n' > kubeconfig.b64

# Copy content and add as KUBE_CONFIG secret in GitHub
cat kubeconfig.b64
```

### Configure kubectl Context

```bash
# List contexts
kubectl config get-contexts

# Switch context
kubectl config use-context default

# Set default namespace
kubectl config set-context --current --namespace=mosuon
```

## Database Access

### PostgreSQL Access

#### From Cluster (kubectl exec)

```bash
# Connect to PostgreSQL pod
kubectl exec -it -n infra postgresql-0 -- bash

# Connect to postgres database
psql -U postgres

# Connect to specific database
psql -U postgres -d game_stats

# List databases
\l

# List users
\du

# Connect to database and list tables
\c game_stats
\dt
```

#### From Local Machine (Port Forward)

```bash
# Forward PostgreSQL port
kubectl port-forward -n infra svc/postgresql 5432:5432

# In another terminal, connect
psql "postgresql://postgres:${POSTGRES_PASSWORD}@localhost:5432/game_stats"

# Or use GUI tool (pgAdmin, DBeaver, etc.)
# Host: localhost
# Port: 5432
# User: postgres
# Password: [your-postgres-password]
# Database: game_stats
```

#### Create Read-Only User

```bash
kubectl exec -it -n infra postgresql-0 -- psql -U postgres <<EOF
CREATE ROLE readonly_user WITH LOGIN PASSWORD 'readonly_password';
GRANT CONNECT ON DATABASE game_stats TO readonly_user;
\c game_stats
GRANT USAGE ON SCHEMA public TO readonly_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly_user;
EOF
```

### Redis Access

```bash
# Connect to Redis pod
kubectl exec -it -n infra redis-master-0 -- redis-cli

# Authenticate
AUTH your-redis-password

# Test commands
PING
INFO
KEYS *

# From local machine (port forward)
kubectl port-forward -n infra svc/redis-master 6379:6379
redis-cli -h localhost -p 6379 -a your-redis-password
```

## Monitoring Access

### ArgoCD

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo

# Access UI
open https://argocd.ultimatestats.co.ke
# Username: admin
# Password: [from above command]
```

#### ArgoCD CLI

```bash
# Install ArgoCD CLI
brew install argocd

# Login
argocd login argocd.ultimatestats.co.ke
# Username: admin
# Password: [admin password]

# List applications
argocd app list

# Get app status
argocd app get game-stats-api
```

### Grafana

```bash
# Get admin password
kubectl get secret -n infra grafana-admin-credentials \
  -o jsonpath="{.data.admin-password}" | base64 -d
echo

# Access UI
open https://grafana.ultimatestats.co.ke
# Username: admin
# Password: [from above command]
```

### Prometheus

```bash
# Port forward Prometheus
kubectl port-forward -n infra svc/prometheus-server 9090:9090

# Access UI
open http://localhost:9090

# Query examples
up
rate(http_requests_total[5m])
```

## Security Best Practices

### 1. Principle of Least Privilege

```bash
# Create service-specific users
kubectl create serviceaccount developer -n mosuon

# Create role with limited permissions
kubectl create role pod-reader \
  --verb=get,list,watch \
  --resource=pods \
  -n mosuon

# Bind role to user
kubectl create rolebinding developer-pod-reader \
  --role=pod-reader \
  --serviceaccount=mosuon:developer \
  -n mosuon
```

### 2. Rotate Credentials Regularly

```bash
# Rotate PostgreSQL password (every 90 days)
NEW_PASSWORD=$(openssl rand -base64 32)
kubectl exec -n infra postgresql-0 -- psql -U postgres -c \
  "ALTER USER postgres PASSWORD '${NEW_PASSWORD}';"

# Update secret
kubectl patch secret game-stats-api-secrets -n mosuon \
  --type merge \
  -p "{\"data\":{\"POSTGRES_PASSWORD\":\"$(echo -n $NEW_PASSWORD | base64)\"}}"

# Rotate JWT secret
NEW_JWT=$(openssl rand -base64 32)
kubectl patch secret game-stats-api-secrets -n mosuon \
  --type merge \
  -p "{\"data\":{\"JWT_SECRET\":\"$(echo -n $NEW_JWT | base64)\"}}"
```

### 3. Use Secrets Management

```bash
# Never commit secrets to Git
echo "*.secret" >> .gitignore
echo ".env" >> .gitignore

# Use sealed-secrets for GitOps
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.18.0/controller.yaml

# Encrypt secret
kubeseal --format=yaml < secret.yaml > sealed-secret.yaml
```

### 4. Enable Audit Logging

```bash
# Enable K3s audit logging
sudo nano /etc/systemd/system/k3s.service

# Add flags:
--kube-apiserver-arg=audit-log-path=/var/log/kubernetes/audit.log
--kube-apiserver-arg=audit-policy-file=/etc/kubernetes/audit-policy.yaml

sudo systemctl daemon-reload
sudo systemctl restart k3s
```

### 5. Network Policies

```bash
# Restrict pod-to-pod communication
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: mosuon
spec:
  podSelector: {}
  policyTypes:
  - Ingress
EOF
```

### 6. Regular Backups

```bash
# Backup PostgreSQL
kubectl exec -n infra postgresql-0 -- pg_dumpall -U postgres | gzip > backup-$(date +%Y%m%d).sql.gz

# Backup Kubernetes manifests
kubectl get all -A -o yaml > k8s-backup-$(date +%Y%m%d).yaml
```

## Access Checklist

Before handing over to team members:

- [ ] SSH keys distributed and tested
- [ ] GitHub PAT created with correct scopes
- [ ] Docker Hub credentials configured
- [ ] kubeconfig shared securely
- [ ] PostgreSQL passwords documented
- [ ] ArgoCD admin password shared
- [ ] Grafana credentials shared
- [ ] All secrets stored in password manager
- [ ] MFA enabled on all accounts
- [ ] Access audit log enabled
- [ ] Backup procedures tested

## Emergency Access

### Lost SSH Access

1. Use VPS provider's console/VNC
2. Reset root password
3. Re-add SSH keys

### Lost kubeconfig

```bash
# SSH into VPS
ssh mosuon-prod

# Get new kubeconfig
sudo cat /etc/rancher/k3s/k3s.yaml
```

### Lost Database Credentials

```bash
# Get from Kubernetes secret
kubectl get secret game-stats-api-secrets -n mosuon -o yaml

# Decode password
echo "base64-encoded-password" | base64 -d
```

### Locked Out of ArgoCD

```bash
# Reset admin password
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {
    "admin.password": "'$(htpasswd -nbBC 10 admin newpassword | cut -d: -f2)'",
    "admin.passwordMtime": "'$(date +%FT%T%Z)'"
  }}'
```

## Support Contacts

- **DevOps Lead**: devops@mosuon.com
- **Security Issues**: security@mosuon.com
- **Emergency**: +254-XXX-XXXXXX
