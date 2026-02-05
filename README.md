# Mosuon DevOps for Kubernetes

This repository contains DevOps assets for deploying Mosuon applications to a Kubernetes cluster (207.180.237.35) using GitHub Actions, Helm, and Argo CD.

## 🚀 Quick Start

See [SETUP.md](SETUP.md) for fast-track deployment guide.

## Infrastructure

**Cluster**: 207.180.237.35 (Mosuon Production VPS)
**Namespace**: `mosuon`
**Deployed Applications**:
- `game-stats-api` - Game statistics backend (Go + Chi + Ent + PostgreSQL)
- `game-stats-ui` - Game statistics frontend (Next.js 15 PWA)

## Quick Links

- **Getting Started** (Follow in Order)
  - [1. Access Setup (Manual)](docs/comprehensive-access-setup.md) 🔐 - SSH keys, GitHub PAT/token
  - [2. Cluster Setup (Automated)](docs/CLUSTER-SETUP-WORKFLOW.md) ⚙️ - Complete setup workflow guide
  - [3. Provisioning (Automated)](docs/provisioning.md) 🚀 - Infrastructure provisioning workflow
  - [4. Onboarding a repo](docs/onboarding.md)

- **Deployment**
  - [Pipelines and workflows](docs/pipelines.md)
  - [GitHub secrets required](docs/github-secrets.md)
  - [ArgoCD setup and GitOps](docs/pipelines.md)

- **Infrastructure**
  - [Database setup (PostgreSQL + Redis)](docs/database-setup.md)
  - [Certificates, domains, and ingress](docs/domains-gateway.md)

- **Operations**
  - [Operations runbook](docs/OPERATIONS-RUNBOOK.md) 📋
  - [Health checks & rolling updates](docs/health-checks-and-rolling-updates.md) 🔄
  - [Monitoring (Prometheus, Grafana)](docs/monitoring.md)
  - [Scaling (HPA, VPA)](docs/scaling.md)

## Repository Structure

```
mosuon-devops-k8s/
├── .github/workflows/       # GitHub Actions CI/CD pipelines
│   └── provision.yml        # Cluster provisioning workflow
├── apps/                    # ArgoCD Application definitions
│   ├── game-stats-api/      # Game Stats API
│   │   ├── app.yaml        # ArgoCD Application
│   │   └── values.yaml     # Helm values
│   ├── game-stats-ui/       # Game Stats UI
│   │   ├── app.yaml        # ArgoCD Application
│   │   └── values.yaml     # Helm values
│   └── root-app.yaml       # App-of-apps pattern
├── charts/                  # Helm charts
│   └── app/                 # Generic application chart
├── scripts/                 # Automation scripts
│   ├── infrastructure/      # Infrastructure setup scripts
│   └── helm/               # Helm utility scripts
└── docs/                    # Documentation

```

## Deployment Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  VPS: 207.180.237.35 (Mosuon Production)                    │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Kubernetes Cluster                                    │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │  Namespace: mosuon                               │  │  │
│  │  │  ┌──────────────────┐  ┌──────────────────┐     │  │  │
│  │  │  │ game-stats-api   │  │ game-stats-ui    │     │  │  │
│  │  │  │ (Go Backend)     │  │ (Next.js PWA)    │     │  │  │
│  │  │  │ Port: 8080       │  │ Port: 3000       │     │  │  │
│  │  │  └──────────────────┘  └──────────────────┘     │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │  Namespace: infra                                │  │  │
│  │  │  ┌────────────┐  ┌────────┐  ┌──────────┐       │  │  │
│  │  │  │ PostgreSQL │  │ Redis  │  │ RabbitMQ │       │  │  │
│  │  │  └────────────┘  └────────┘  └──────────┘       │  │  │
│  │  │  ┌──────────┐  ┌────────────┐                   │  │  │
│  │  │  │ Superset │  │ Prometheus │                   │  │  │
│  │  │  └──────────┘  └────────────┘                   │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │  Namespace: argocd                               │  │  │
│  │  │  ┌───────────────────┐                           │  │  │
│  │  │  │ Argo CD Server    │ (GitOps)                  │  │  │
│  │  │  └───────────────────┘                           │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Application Onboarding

To add a new application to the Mosuon cluster:

1. **Add build.sh** to your app repository (see [docs/onboarding.md](docs/onboarding.md))
2. **Create ArgoCD Application** in `apps/your-app/`
3. **Create Helm values** in `apps/your-app/values.yaml`
4. **Update root-app.yaml** to include your app
5. **Push to main branch** - ArgoCD will auto-deploy

## Infrastructure Components

### Shared Services (infra namespace)
- **PostgreSQL** - Shared database with per-service databases
- **Redis** - Caching and sessions
- **RabbitMQ** - Message queue
- **Superset** - Data analytics platform
- **Prometheus + Grafana** - Monitoring stack

### Per-Service Databases
- `game_stats` - Game statistics database
- Each service creates its own database during deployment

## GitHub Secrets Required

```
KUBE_CONFIG              # Base64-encoded kubeconfig
POSTGRES_PASSWORD        # Master password for all infrastructure
REGISTRY_USERNAME        # Docker Hub username
REGISTRY_PASSWORD        # Docker Hub password
SSH_HOST                 # VPS IP (207.180.237.35)
GH_PAT                   # GitHub Personal Access Token
```

See [docs/github-secrets.md](docs/github-secrets.md) for full list.

## CI/CD Pipeline

```
Developer Push → GitHub Actions → Build Image → Push to Registry
                                                      ↓
                                            Update ArgoCD values
                                                      ↓
                        ArgoCD ← Sync ← Git Repository
                           ↓
                    Deploy to Cluster
```

## Domains

- **ArgoCD**: https://argocd.ultimatestats.co.ke
- **Grafana**: https://grafana.ultimatestats.co.ke
- **Game Stats UI**: https://stats.ultimatestats.co.ke
- **Game Stats API**: https://api.stats.ultimatestats.co.ke

## Support

For issues or questions:
- Check [docs/](docs/)
- Review [OPERATIONS-RUNBOOK.md](docs/OPERATIONS-RUNBOOK.md)
- Contact DevOps team
