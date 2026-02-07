# Centralized Secret Management System

## Overview

This system provides automated secret management across all mosuon repositories using centralized scripts in `mosuon-devops-k8s`. Applications automatically check for missing secrets and sync them from the DevOps repository during build time, eliminating manual secret configuration.

## Architecture

```
mosuon-devops-k8s (Bengo-Hub org)
└── scripts/tools/
    ├── set-propagate-secrets.sh      # Initialize PROPAGATE_SECRETS from exported file
    ├── propagate-to-repo.sh          # Propagate specific secrets to target repo
    └── check-and-sync-secrets.sh     # Auto-sync helper for build.sh scripts

Application repos (game-stats-api, game-stats-ui)
└── build.sh
    └── Downloads check-and-sync-secrets.sh from mosuon-devops-k8s
    └── Auto-syncs missing secrets before deployment
```

## Components

### 1. set-propagate-secrets.sh
**Purpose**: Initialize or update the PROPAGATE_SECRETS repository secret from an exported secrets file.

**Usage**:
```bash
SECRETS_FILE=/path/to/secrets.txt bash set-propagate-secrets.sh
```

### 2. propagate-to-repo.sh
**Purpose**: Propagate specific secrets to a target repository.

**Usage**:
```bash
./propagate-to-repo.sh <target-repo> <secret1> [secret2] ...
```

**Examples**:
```bash
# Propagate multiple secrets to game-stats-api
./propagate-to-repo.sh Bengo-Hub/game-stats-api POSTGRES_PASSWORD REDIS_PASSWORD KUBE_CONFIG

# Propagate single secret to game-stats-ui
./propagate-to-repo.sh Bengo-Hub/game-stats-ui REGISTRY_PASSWORD
```

### 3. check-and-sync-secrets.sh
**Purpose**: Helper function for application build.sh scripts to auto-check and sync missing secrets.

**Usage in build.sh**:
```bash
# Download and source the sync script
SYNC_SCRIPT=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/Bengo-Hub/mosuon-devops-k8s/master/scripts/tools/check-and-sync-secrets.sh -o "$SYNC_SCRIPT"
source "$SYNC_SCRIPT"

# Call the function with required secrets
check_and_sync_secrets "KUBE_CONFIG" "REGISTRY_USERNAME" "REGISTRY_PASSWORD" "GITHUB_TOKEN"

# Cleanup
rm -f "$SYNC_SCRIPT"
```

---

## Modified Apps

**Bengo-Hub/mosuon-devops-k8s apps**:
- `mosuon/game-stats/game-stats-api/build.sh` ✅
- `mosuon/game-stats/game-stats-ui/build.sh` ✅

---

## Setup Guide

### Initial Setup

1. **Export secrets**:
   ```bash
   # Export secrets from Kubernetes cluster or existing sources
   # Save to: D:/KubeSecrets/git-secrets/Bengo-Hub__mosuon-devops-k8s/secrets.txt
   ```

2. **Authenticate GitHub CLI**:
   ```bash
   gh auth login
   ```

3. **Initialize PROPAGATE_SECRETS**:
   ```bash
   cd mosuon-devops-k8s/scripts/tools
   SECRETS_FILE=D:/KubeSecrets/git-secrets/Bengo-Hub__mosuon-devops-k8s/secrets.txt bash set-propagate-secrets.sh
   ```

4. **Set PROPAGATE_PAT** (one-time):
   ```bash
   echo "ghp_YOUR_TOKEN_HERE" | gh secret set PROPAGATE_PAT --repo Bengo-Hub/mosuon-devops-k8s
   ```

5. **Test propagation**:
   ```bash
   cd mosuon-devops-k8s/scripts/tools
   ./propagate-to-repo.sh Bengo-Hub/game-stats-api KUBE_CONFIG POSTGRES_PASSWORD
   ```

---

## Summary

This system provides:
- ✅ **Zero-touch secret provisioning** for new repositories
- ✅ **Automated secret syncing** during build time
- ✅ **Centralized secret storage** in mosuon-devops-k8s
- ✅ **No manual secret configuration** required
- ✅ **Built-in fallback** if sync fails

---

**Last Updated**: January 2025  
**Maintainer**: DevOps Team
