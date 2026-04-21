#!/usr/bin/env bash
set -euo pipefail

echo "=== [1/7] Reading Vault credentials ==="
if [[ ! -f /tmp/vault-root-token.txt ]]; then
  echo "ERROR: /tmp/vault-root-token.txt not found. Run 01-vault-install.sh first."
  exit 1
fi

ROOT_TOKEN=$(cat /tmp/vault-root-token.txt)
VAULT_POD="vault-0"
VAULT_NS="vault"

vault_exec() {
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- env VAULT_TOKEN="$ROOT_TOKEN" vault "$@"
}

echo "=== [2/7] Enabling KV v2 secrets engine ==="
vault_exec secrets enable -path=secret kv-v2 2>/dev/null || echo "  (already enabled, skipping)"

echo "=== [3/7] Writing PostgreSQL credentials ==="
vault_exec kv put secret/itssolutions/db-creds \
  host="postgres-service.itssolutions-db.svc.cluster.local" \
  port="5432" \
  database="itssolutions_db" \
  username="itssolutions" \
  password="SecurePass123!"

echo "=== [4/7] Writing app config (JWT secret) ==="
vault_exec kv put secret/itssolutions/app-config \
  jwt_secret="$(openssl rand -base64 48)"

echo "=== [5/7] Enabling Kubernetes auth method ==="
vault_exec auth enable kubernetes 2>/dev/null || echo "  (already enabled, skipping)"

# Fetch Kubernetes API info from inside the pod
K8S_HOST="https://kubernetes.default.svc.cluster.local"
K8S_CA=$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)
SA_TOKEN=$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)

kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
  env VAULT_TOKEN="$ROOT_TOKEN" \
  vault write auth/kubernetes/config \
    kubernetes_host="$K8S_HOST" \
    kubernetes_ca_cert="$K8S_CA" \
    token_reviewer_jwt="$SA_TOKEN" \
    issuer="https://kubernetes.default.svc.cluster.local"

echo "=== [6/7] Creating Vault policy 'itssolutions-policy' ==="
kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
  env VAULT_TOKEN="$ROOT_TOKEN" \
  vault policy write itssolutions-policy - <<'POLICY'
path "secret/data/itssolutions/*" {
  capabilities = ["read", "list"]
}
POLICY

echo "=== [7/7] Creating Vault Kubernetes auth role 'itssolutions-backend' ==="
vault_exec write auth/kubernetes/role/itssolutions-backend \
  bound_service_account_names="backend-sa" \
  bound_service_account_namespaces="itssolutions-prod" \
  policies="itssolutions-policy" \
  ttl="1h"

echo ""
echo "✅  Vault configuration complete."
