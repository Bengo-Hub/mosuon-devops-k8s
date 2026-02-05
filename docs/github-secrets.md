# GitHub Secrets Configuration Guide

Complete list of GitHub repository secrets required for CI/CD pipelines and infrastructure provisioning.

## Overview

GitHub Secrets store sensitive credentials securely for use in GitHub Actions workflows. These secrets are encrypted and only exposed to workflows during execution.

**Repository**: `Bengo-Hub/mosuon-devops-k8s`
**Path**: Settings → Secrets and variables → Actions → Repository secrets

## Required Secrets

### 1. KUBE_CONFIG

**Description**: Base64-encoded Kubernetes configuration file for cluster access.

**How to Generate**:
```bash
# On local machine with kubectl configured
cat ~/.kube/mosuon-config | base64 -w 0 > kubeconfig.b64

# On macOS
cat ~/.kube/mosuon-config | base64 | tr -d '\n' > kubeconfig.b64

# Copy content
cat kubeconfig.b64
```

**Format**: Base64-encoded YAML

**Example** (truncated):
```
LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUM2VENDQWRHZ0F3SUJBZ0lCQURBTkJna3Foa2lH...
```

**Used By**:
- `.github/workflows/provision.yml`
- Application build scripts via workflow

**Rotation**: Every 90 days or when cluster is rebuilt

---

### 2. POSTGRES_PASSWORD

**Description**: Master password for PostgreSQL database server.

**How to Generate**:
```bash
# Generate strong random password
openssl rand -base64 32

# Example output
Xk9P2mNqR7vB3wJ8yL4nT6sK1hF5gD9cA0eV
```

**Format**: Alphanumeric string (32+ characters)

**Security**: 
- Minimum 32 characters
- Mix of uppercase, lowercase, numbers
- No special characters that need escaping in connection strings

**Used By**:
- PostgreSQL Helm chart installation
- Application database user creation
- Application DATABASE_URL secret
- Redis authentication (reused)

**Shared With**:
- PostgreSQL server (`auth.postgresPassword`)
- Application secrets (`DATABASE_URL`, `REDIS_PASSWORD`)

**Rotation**: Every 90 days

**Rotation Process**:
```bash
# 1. Generate new password
NEW_PASS=$(openssl rand -base64 32)

# 2. Update PostgreSQL
kubectl exec -n infra postgresql-0 -- psql -U postgres -c \
  "ALTER USER postgres PASSWORD '${NEW_PASS}';"

# 3. Update application secrets
kubectl patch secret game-stats-api-secrets -n mosuon \
  --type merge \
  -p "{\"data\":{\"POSTGRES_PASSWORD\":\"$(echo -n $NEW_PASS | base64)\"}}"

# 4. Update GitHub secret
gh secret set POSTGRES_PASSWORD --body "$NEW_PASS"

# 5. Restart applications
kubectl rollout restart deployment -n mosuon
```

---

### 3. REGISTRY_USERNAME

**Description**: Docker Hub username for container registry authentication.

**How to Get**: Your Docker Hub account username

**Format**: Lowercase alphanumeric

**Example**: `codevertex`

**Used By**:
- Docker login in build scripts
- Kubernetes imagePullSecrets creation
- Image push operations

**Paired With**: `REGISTRY_PASSWORD`

---

### 4. REGISTRY_PASSWORD

**Description**: Docker Hub access token (not account password!).

**How to Generate**:
1. Login to https://hub.docker.com
2. Go to Account Settings → Security
3. Click "New Access Token"
4. Name: "mosuon-cluster-ci"
5. Permissions: Read, Write, Delete
6. Click "Generate"
7. Copy the token (shown once!)

**Format**: `dckr_pat_` prefix followed by token

**Example**: `dckr_pat_Xk9P2mNqR7vB3wJ8yL4nT6sK1h`

**Security**:
- NEVER use account password
- Use access tokens for automation
- Tokens can be revoked without changing account password

**Used By**:
- `docker login` in build scripts
- Registry credentials secret creation

**Rotation**: Every 180 days

**Rotation Process**:
```bash
# 1. Create new token on Docker Hub

# 2. Update GitHub secret
gh secret set REGISTRY_PASSWORD --body "dckr_pat_new_token"

# 3. Update Kubernetes secrets
kubectl delete secret registry-credentials -n mosuon
kubectl create secret docker-registry registry-credentials \
  --docker-server=docker.io \
  --docker-username=$REGISTRY_USERNAME \
  --docker-password=$REGISTRY_PASSWORD \
  -n mosuon

# 4. Revoke old token on Docker Hub
```

---

### 5. SSH_HOST

**Description**: VPS IP address for SSH connections.

**Value**: `207.180.237.35`

**Format**: IPv4 address

**Used By**:
- Provisioning workflow (optional)
- Remote script execution
- Cluster management automation

**When to Update**: 
- VPS IP changes
- Moving to different hosting provider

---

### 6. GH_PAT

**Description**: GitHub Personal Access Token for repository operations.

**How to Generate**:
1. Go to https://github.com/settings/tokens
2. Click "Generate new token (classic)"
3. Name: "mosuon-devops-automation"
4. Expiration: 90 days
5. Select scopes:
   - ✅ `repo` - Full control of private repositories
   - ✅ `workflow` - Update GitHub Actions workflows  
   - ✅ `read:packages` - Download packages
   - ✅ `write:packages` - Upload packages
6. Click "Generate token"
7. Copy token (shown once!)

**Format**: `ghp_` prefix followed by token

**Example**: `ghp_Xk9P2mNqR7vB3wJ8yL4nT6sK1hF5gD9cA0eV`

**Used By**:
- Cloning mosuon-devops-k8s repository
- Updating Helm values after build
- Git push operations in build scripts

**Scopes Required**:
```yaml
- repo            # Access private repositories
- workflow        # Update workflows
- read:packages   # Pull container images
- write:packages  # Push container images
```

**Rotation**: Every 90 days (GitHub enforces expiration)

**Rotation Process**:
```bash
# 1. Generate new token on GitHub

# 2. Update GitHub secret
gh secret set GH_PAT --body "ghp_new_token"

# 3. Test git operations
git clone https://ghp_new_token@github.com/Bengo-Hub/mosuon-devops-k8s.git
```

---

### 7. JWT_SECRET

**Description**: Secret key for signing JWT authentication tokens.

**How to Generate**:
```bash
# Generate cryptographically secure random secret
openssl rand -base64 64

# Example output
Xk9P2mNqR7vB3wJ8yL4nT6sK1hF5gD9cA0eVXk9P2mNqR7vB3wJ8yL4nT6sK1hF5gD9cA0eV
```

**Format**: Base64 string (64+ characters)

**Security**:
- Minimum 64 characters
- High entropy random bytes
- NEVER share or commit to Git
- Different secret for each environment (dev/staging/prod)

**Used By**:
- Game Stats API JWT signing
- Token verification
- Authentication middleware

**Rotation**: Every 180 days or when compromised

**Rotation Process**:
```bash
# 1. Generate new secret
NEW_JWT=$(openssl rand -base64 64)

# 2. Update GitHub secret
gh secret set JWT_SECRET --body "$NEW_JWT"

# 3. Deploy new secret to cluster
kubectl create secret generic game-stats-api-secrets \
  --from-literal=JWT_SECRET="$NEW_JWT" \
  --namespace=mosuon \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Gradual rollout (to prevent invalidating all tokens at once)
# Keep both secrets temporarily, update deployment, then remove old secret
```

**Impact of Rotation**:
- ⚠️ All existing JWT tokens become invalid
- Users will need to re-authenticate
- Plan rotation during low-traffic periods
- Consider grace period with dual-secret validation

---

## Optional Secrets

### 8. SENTRY_DSN

**Description**: Sentry error tracking DSN (Data Source Name).

**How to Get**:
1. Create project on https://sentry.io
2. Copy DSN from project settings

**Format**: `https://xxx@o123.ingest.sentry.io/456`

**Used By**: Application error reporting

---

### 9. SLACK_WEBHOOK_URL

**Description**: Slack webhook for deployment notifications.

**How to Generate**:
1. Go to https://api.slack.com/apps
2. Create new app → Incoming Webhooks
3. Activate webhooks
4. Add webhook to channel
5. Copy webhook URL

**Format**: `https://hooks.slack.com/services/T00/B00/xxx`

**Used By**: Workflow notification steps

---

### 10. BACKUP_S3_ACCESS_KEY / BACKUP_S3_SECRET_KEY

**Description**: AWS S3 credentials for database backups.

**How to Get**: AWS IAM → Create access key

**Used By**: Backup scripts uploading to S3

---

## Setting Secrets via GitHub UI

### Step-by-Step

1. Navigate to repository: https://github.com/Bengo-Hub/mosuon-devops-k8s

2. Click "Settings" tab

3. In left sidebar, click "Secrets and variables" → "Actions"

4. Click "New repository secret" button

5. Enter:
   - **Name**: Secret name (e.g., `KUBE_CONFIG`)
   - **Secret**: Secret value
   
6. Click "Add secret"

7. Repeat for all required secrets

### Screenshot Reference

```
Settings > Secrets and variables > Actions
┌─────────────────────────────────────────────┐
│ Repository secrets                          │
│                                             │
│ KUBE_CONFIG               Updated 2 days ago│
│ POSTGRES_PASSWORD         Updated 2 days ago│
│ REGISTRY_USERNAME         Updated 2 days ago│
│ REGISTRY_PASSWORD         Updated 2 days ago│
│ GH_PAT                    Updated 2 days ago│
│ JWT_SECRET                Updated 2 days ago│
│                                             │
│ [New repository secret]                     │
└─────────────────────────────────────────────┘
```

## Setting Secrets via GitHub CLI

### Prerequisites

```bash
# Install GitHub CLI
brew install gh

# Login
gh auth login
```

### Commands

```bash
# Set single secret
gh secret set KUBE_CONFIG < kubeconfig.b64

# Set from stdin
echo "my-secret-value" | gh secret set SECRET_NAME

# Set interactively
gh secret set POSTGRES_PASSWORD
# Paste secret value
# Press Ctrl+D

# List all secrets
gh secret list

# Delete secret
gh secret delete OLD_SECRET
```

### Bulk Import

```bash
# Create .env file (DO NOT COMMIT!)
cat > .env <<EOF
KUBE_CONFIG=$(cat ~/.kube/mosuon-config | base64 -w 0)
POSTGRES_PASSWORD=$(openssl rand -base64 32)
REGISTRY_USERNAME=codevertex
REGISTRY_PASSWORD=dckr_pat_xxx
GH_PAT=ghp_xxx
JWT_SECRET=$(openssl rand -base64 64)
EOF

# Import all secrets
gh secret set -f .env

# Securely delete .env
shred -u .env
```

## Verifying Secrets

### Check Secret Exists

```bash
# List all secrets
gh secret list

# Expected output:
# KUBE_CONFIG          Updated TIMESTAMP
# POSTGRES_PASSWORD    Updated TIMESTAMP
# REGISTRY_USERNAME    Updated TIMESTAMP
# REGISTRY_PASSWORD    Updated TIMESTAMP
# GH_PAT              Updated TIMESTAMP
# JWT_SECRET          Updated TIMESTAMP
```

### Test in Workflow

Create `.github/workflows/test-secrets.yml`:

```yaml
name: Test Secrets

on: workflow_dispatch

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Test Secret Existence
        env:
          KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
          POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
        run: |
          if [ -z "$KUBE_CONFIG" ]; then
            echo "❌ KUBE_CONFIG is not set"
            exit 1
          fi
          if [ -z "$POSTGRES_PASSWORD" ]; then
            echo "❌ POSTGRES_PASSWORD is not set"
            exit 1
          fi
          echo "✅ All secrets configured"
```

## Security Best Practices

### 1. Never Commit Secrets

```bash
# Add to .gitignore
cat >> .gitignore <<EOF
*.secret
*.key
.env
kubeconfig*
*.b64
EOF
```

### 2. Use Secret Scanning

Enable in repository settings:
- Settings → Code security and analysis
- Enable "Secret scanning"
- Enable "Push protection"

### 3. Rotate Regularly

| Secret | Rotation Frequency |
|--------|-------------------|
| KUBE_CONFIG | 90 days |
| POSTGRES_PASSWORD | 90 days |
| REGISTRY_PASSWORD | 180 days |
| GH_PAT | 90 days (enforced) |
| JWT_SECRET | 180 days |

### 4. Principle of Least Privilege

- Use read-only tokens where possible
- Scope GitHub PAT to specific repos
- Use separate tokens for different workflows

### 5. Audit Secret Access

```bash
# Check workflow runs using secrets
gh run list --workflow=provision.yml

# View workflow logs (secrets are masked)
gh run view <run-id> --log
```

### 6. Emergency Revocation

If secret is compromised:

```bash
# 1. Immediately revoke/rotate
gh secret delete COMPROMISED_SECRET

# 2. Generate new value
NEW_VALUE=$(openssl rand -base64 32)

# 3. Update secret
gh secret set COMPROMISED_SECRET --body "$NEW_VALUE"

# 4. Update cluster
kubectl patch secret ... # Update affected K8s secrets

# 5. Redeploy applications
kubectl rollout restart deployment -n mosuon

# 6. Audit logs for unauthorized access
```

## Troubleshooting

### Secret Not Available in Workflow

```yaml
# Check secret name matches exactly (case-sensitive)
env:
  POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}  # ✅ Correct
  postgres_password: ${{ secrets.POSTGRES_PASSWORD }}  # ✅ Also works
  POSTGRES_PASSWORD: ${{ secrets.postgres_password }}  # ❌ Wrong secret name
```

### Secret Value Contains Special Characters

```bash
# URL encode or base64 encode secrets with special chars
echo -n "secret@with$pecial!chars" | base64

# In workflow, decode:
echo "${{ secrets.ENCODED_SECRET }}" | base64 -d
```

### Secret Too Large

GitHub secret limit: 64KB

```bash
# Check size
wc -c kubeconfig.b64
# If > 65536 bytes, secret is too large

# Solution: Store in artifact or external secret manager
```

## Secret Management Checklist

Before going to production:

- [ ] All required secrets configured
- [ ] Secrets tested in workflow run
- [ ] Secret values documented in password manager
- [ ] Rotation schedule created
- [ ] Access audit logging enabled
- [ ] Emergency contact list for secret issues
- [ ] Backup of secrets in secure vault
- [ ] Team members have access to password manager
- [ ] Secret rotation runbook documented

## Related Documentation

- [Access Setup Guide](comprehensive-access-setup.md)
- [Provisioning Workflow](provisioning.md)
- [CI/CD Pipelines](pipelines.md)
