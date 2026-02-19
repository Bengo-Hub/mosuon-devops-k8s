# Initial manual cluster setup — pre-provision checklist

This document contains the one-time manual steps you must complete on the VPS and in GitHub **before** running the automated provisioning workflows in `mosuon-devops-k8s`.

Purpose: bring a bare Ubuntu VPS to a state where the provisioning GitHub Actions workflow can safely and reliably install monitoring, infra services and application Helm charts.

Estimated time: 10–25 minutes

---

## Quick checklist (do these first)

- [ ] SSH key + login working (password or SSH key) on the VPS
- [ ] DNS control for your domains (optional for TLS, required for cert-manager)
- [ ] Local tools installed: `kubectl`, `helm`, `gh`, `yq` (for local debugging)
- [ ] GitHub repo secrets created: `KUBE_CONFIG` (after kubeconfig generated), `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`, `POSTGRES_PASSWORD`, `GH_PAT`, `SSH_HOST`

---

## 1) VPS prep (one-time)

1. SSH into VPS (example):

   ssh root@207.180.237.35

   Or run the automated VPS + Kubernetes bootstrap from your workstation (recommended):

   ```bash
   # from repo root
   ./scripts/infrastructure/run-remote-setup.sh root@207.180.237.35

   # or run and auto-push kubeconfig to this repo's GitHub secrets (requires 'gh' CLI auth)
   ./scripts/infrastructure/run-remote-setup.sh root@207.180.237.35 --push-secret
   ```

2. Update OS and install essentials:

   apt update && apt upgrade -y
   apt install -y curl wget git ufw ca-certificates gnupg lsb-release

3. Configure firewall (allow SSH / HTTP / HTTPS):

   ufw allow 22/tcp
   ufw allow 80/tcp
   ufw allow 443/tcp
   ufw --force enable

4. (Optional — harden): disable password auth after you add your public key to `~/.ssh/authorized_keys`.

---

## 2) Install lightweight Kubernetes (k3s) — manual

The provisioning workflows expect a working kubeconfig. Install Kubernetes (k3s is supported) now if the cluster isn't already present.

1. Install k3s (single-node example):

   curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644 --disable traefik --disable servicelb

2. Verify cluster is Ready:

   kubectl get nodes

3. Copy kubeconfig to your workstation (or encode for GitHub secret):

   scp root@207.180.237.35:/etc/rancher/k3s/k3s.yaml ~/.kube/mosuon-config
   sed -i 's/127.0.0.1/207.180.237.35/' ~/.kube/mosuon-config

4. Base64-encode for GitHub Actions `KUBE_CONFIG` secret:

   cat ~/.kube/mosuon-config | base64 -w 0 > kubeconfig.b64

   Copy the single-line output and add it as repository secret `KUBE_CONFIG`.

---

## 3) Install ingress & cert-manager (manual, optional — provisioning can install these)

If you prefer to install these manually before provisioning runs, do the following:

1. Install NGINX ingress-controller:

   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml

2. Install cert-manager:

   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.crds.yaml
   helm repo add jetstack https://charts.jetstack.io
   helm repo update
   helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.13.0

3. Wait for readiness:

   kubectl get pods -n ingress-nginx
   kubectl get pods -n cert-manager

---

## 4) (Optional) Install monitoring now — otherwise provisioning installs it

Manual install (Helm) for Prometheus + Grafana if you want dashboards immediately:

   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update
   helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f /dev/null \
     --set prometheus.prometheusSpec.retention=30d --wait --timeout=10m

Verify:

   kubectl get pods -n monitoring

---

## 5) GitHub secrets — create BEFORE running provisioning

Required (minimum):

- `KUBE_CONFIG` — base64 kubeconfig from step 2 (required)
- `SSH_HOST` — VPS public IP (e.g. `207.180.237.35`)
- `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` — Docker registry credentials
- `POSTGRES_PASSWORD` — initial DB password
- `GH_PAT` — GitHub PAT used by workflows (optional but recommended)

How to add `KUBE_CONFIG`:

1. Copy base64 from `kubeconfig.b64` (single-line)
2. GitHub → repo `Settings → Secrets and variables → Actions → New repository secret`
3. Name: `KUBE_CONFIG` → Paste value → Save

---

## 6) Quick verification (must pass before provisioning)

- kubectl --kubeconfig=~/.kube/mosuon-config get nodes  → nodes show Ready
- kubectl --kubeconfig=~/.kube/mosuon-config get pods -A  → system pods running
- gh secret list --repo Bengo-Hub/mosuon-devops-k8s  → verify required secrets exist

If all checks pass, you can now run the provisioning workflow: `Actions → Provision Infrastructure → Run workflow`.

---

## Troubleshooting

- `kubectl: permission denied` → check kubeconfig `server:` address matches VPS public IP
- `cert-manager pod CrashLoop` → check DNS resolution for ingress host used by provisioning
- `Helm install times out` → increase `--timeout` & ensure images can be pulled (registry creds)

---

## Next steps after provisioning completes

- Confirm ArgoCD is accessible: https://argocd.YOUR_DOMAIN
- Confirm Grafana (if installed): https://grafana.YOUR_DOMAIN
- Sync ArgoCD `root-app` to bootstrap applications

---

References:
- `docs/CLUSTER-SETUP-WORKFLOW.md` (repo) — canonical provisioning workflow
- `docs/monitoring.md` — monitoring installation details

