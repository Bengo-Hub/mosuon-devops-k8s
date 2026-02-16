# Reprovisioning / full cluster cleanup (Mosuon)

Use this guide when you need to reset the Mosuon cluster and re-run provisioning from scratch.

**Warning:** reprovisioning deletes application data, Helm releases and PVCs. Back up any important data before proceeding.

## When to use

- Persistent corruption or unrecoverable state
- Moving to a new VPS or OS image
- Full clean redeploy for environment parity

## Quick safety checklist

- [ ] Back up PostgreSQL/Redis if needed
- [ ] Export ArgoCD application manifests if you want to preserve configs
- [ ] Confirm GitHub secrets are correct and available

## Fast reprovision steps (recommended)

1. In the repo run the automated cleanup workflow (if available): `Actions → Cleanup / Reprovision → Run workflow`.

2. Manually delete ArgoCD applications (if stuck):

   kubectl delete applications --all -n argocd --wait=false --grace-period=0 || true

3. Delete namespaces used by apps (example):

   for ns in mosuon infra; do kubectl delete namespace $ns --wait=false --grace-period=0 || true; done

4. Remove PVCs and PVs:

   kubectl get pvc -A
   kubectl delete pvc --all -n infra || true

5. Re-run the provisioning workflow in GitHub Actions: `Provision Infrastructure` → Run workflow

## Manual step-by-step (detailed)

1. Scale down ArgoCD controllers to avoid immediate re-creation:

   kubectl scale deployment argocd-application-controller -n argocd --replicas=0 || true

2. Uninstall Helm releases (infra first):

   helm uninstall prometheus -n monitoring || true
   helm uninstall postgresql -n infra || true

3. Force-remove stuck resources and finalizers:

   # Remove finalizers from namespaces
   kubectl get namespace -o json | jq '.items[] | select(.metadata.finalizers != null) | .metadata.name' -r | \
     xargs -n1 -I{} kubectl patch namespace {} -p '{"metadata":{"finalizers":[]}}' --type=merge || true

4. Delete PVs/PVCs and leftover CRDs if required

   kubectl delete pvc --all -n infra --wait=false || true
   kubectl get crd | grep -E "argo|prometheus|alertmanager|grafana" | awk '{print $1}' | xargs -r kubectl delete crd || true

5. Wait for system namespaces to be stable, then re-run provisioning.

## After reprovision

- Re-add DNS records (if removed)
- Verify `kubectl get nodes` and `kubectl get pods -n kube-system`
- Verify GitHub secrets still exist (particularly `KUBE_CONFIG`)

## Notes / differences vs devops-k8s reprovisioning

- Mosuon uses K3s (single-node typical) so some etcd-specific steps are not applicable
- Steps are intentionally conservative—use `--wait=false` for automation-friendly runs

