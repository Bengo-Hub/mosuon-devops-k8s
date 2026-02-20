#!/bin/bash
kubectl patch cm argocd-cmd-params-cm -n argocd -p '{"data":{"server.insecure":"false"}}'
kubectl patch ingress argocd-server -n argocd --type=json -p='[{"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/port/number", "value": 443}]'
kubectl annotate ingress argocd-server -n argocd nginx.ingress.kubernetes.io/backend-protocol=HTTPS nginx.ingress.kubernetes.io/ssl-passthrough=true --overwrite
kubectl rollout restart deployment argocd-server -n argocd

echo "=== Force new certs ==="
kubectl delete certificaterequest --all -A 2>/dev/null || true
kubectl delete certificate --all -A 2>/dev/null || true
sleep 5
kubectl get challenges -A
