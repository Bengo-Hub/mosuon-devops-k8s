#!/bin/bash
set -euo pipefail

echo "=== 1. Patching Metabase Deployment ==="
cat << 'EOF' > /tmp/metabase-patch.json
[
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds", "value": 300},
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds", "value": 120}
]
EOF

kubectl patch deployment metabase -n infra --type json --patch-file /tmp/metabase-patch.json || true
echo "Waiting for Metabase pod to spin up with 300s grace period..."

echo "=== 2. Forcing ArgoCD Sync for Game-Stats ==="
cat << 'APP_SYNC' > /tmp/sync.json
{"operation": {"sync": {"revision": "main"}}}
APP_SYNC
kubectl patch app game-stats-api -n argocd --type merge --patch-file /tmp/sync.json || true
kubectl patch app game-stats-ui -n argocd --type merge --patch-file /tmp/sync.json || true

echo "=== Status ==="
sleep 5
kubectl get pods -n mosuon
kubectl get pods -n infra | grep metabase
