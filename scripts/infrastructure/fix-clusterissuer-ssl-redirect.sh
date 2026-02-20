#!/bin/bash
# =============================================================================
# Fix ClusterIssuer: add ssl-redirect:false to ACME solver ingresses
#
# PROBLEM: nginx force-ssl-redirect:true causes all HTTP requests to return
# 308 Permanent Redirect. LetsEncrypt's HTTP-01 verification hits this redirect
# and the challenge goes invalid, blocking certificate issuance.
#
# FIX: Use ingressTemplate in ClusterIssuer to add nginx.ingress.kubernetes.io/
# ssl-redirect: "false" to cm-acme-http-solver ingresses, overriding the
# redirect for the /.well-known/acme-challenge/ path only.
# =============================================================================

set -euo pipefail

ACME_EMAIL=${ACME_EMAIL:-admin@ultichange.org}

echo "[INFO] Updating ClusterIssuers with ssl-redirect:false ingressTemplate..."

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
          ingressTemplate:
            metadata:
              annotations:
                nginx.ingress.kubernetes.io/ssl-redirect: "false"
                nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
EOF

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
          ingressTemplate:
            metadata:
              annotations:
                nginx.ingress.kubernetes.io/ssl-redirect: "false"
                nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
EOF

echo "[OK] ClusterIssuers updated with ssl-redirect:false"

echo ""
echo "=== Deleting failed CertificateRequests to force fresh orders ==="
kubectl delete certificaterequest --all -n argocd 2>/dev/null || true
kubectl delete certificaterequest --all -n infra 2>/dev/null || true
kubectl delete certificaterequest --all -n monitoring 2>/dev/null || true

echo "[OK] Failed CRs deleted — cert-manager will create new ones"

echo ""
echo "=== Waiting 30s for new challenges to appear ==="
sleep 30

echo ""
echo "=== Active Challenges ==="
kubectl get challenges -A 2>/dev/null || echo "none yet"

echo ""
echo "=== Certificates ==="
kubectl get certificates -A

echo ""
echo "=== ACME solver ingresses ==="
kubectl get ingress -A | grep acme || echo "none"

echo ""
echo "=== Test HTTP-01 path (should NOT redirect) ==="
curl -sv http://argocd.ultichange.org/.well-known/acme-challenge/test 2>&1 | grep -E '(HTTP/|Location:|< HTTP|301|302|308|200|404|Redirect)' | head -5
