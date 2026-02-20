#!/bin/bash
echo "=== Patching ArgoCD ConfigMap ==="
kubectl patch cm argocd-cmd-params-cm -n argocd -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd

echo "=== Patching ArgoCD Ingress ==="
# Remove passthrough and force-redirect
kubectl annotate ingress argocd-server -n argocd \
  nginx.ingress.kubernetes.io/ssl-passthrough- \
  nginx.ingress.kubernetes.io/force-ssl-redirect- 2>/dev/null || true

# Set backend to HTTP and explicitly disable ssl-redirect
kubectl annotate ingress argocd-server -n argocd \
  nginx.ingress.kubernetes.io/backend-protocol=HTTP \
  nginx.ingress.kubernetes.io/ssl-redirect="false" --overwrite

# Patch the backend port
kubectl patch ingress argocd-server -n argocd --type=json -p='[{"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/port/number", "value": 80}]'

echo "=== Cleaning up certs to trigger reissue ==="
kubectl delete certificaterequest --all -A 2>/dev/null || true
kubectl delete certificate --all -A 2>/dev/null || true
kubectl delete challenge --all -A 2>/dev/null || true

echo "Waiting for challenges..."
sleep 10
kubectl get challenges -A
