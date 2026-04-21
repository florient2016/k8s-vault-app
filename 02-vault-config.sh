#!/usr/bin/env bash
set -euo pipefail

echo "=== [02] Configuring HashiCorp Vault ==="

# Load keys from vault-keys.txt
if [ ! -f vault-keys.txt ]; then
  echo "ERROR: vault-keys.txt not found. Run 01-vault-install.sh first."
  exit 1
fi

source vault-keys.txt

# Port-forward Vault for configuration
echo "=== Starting port-forward to Vault ==="
oc -n vault port-forward svc/vault 8200:8200 &
PF_PID=$!
sleep 5

export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="${VAULT_ROOT_TOKEN}"

cleanup() {
  echo "=== Stopping port-forward ==="
  kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Enabling KV secrets engine v2 ==="
vault secrets enable -path=secret kv-v2 2>/dev/null || echo "KV already enabled"

echo "=== Storing PostgreSQL credentials ==="
vault kv put secret/itssolutions/db-creds \
  host="postgres-service.itssolutions-db.svc.cluster.local" \
  port="5432" \
  database="itssolutions_db" \
  username="itssolutions" \
  password="SecurePass123!"

echo "=== Storing app config ==="
vault kv put secret/itssolutions/app-config \
  jwt_secret="$(openssl rand -hex 64)"

echo "=== Writing Vault policy: itssolutions-policy ==="
vault policy write itssolutions-policy - <<'POLICY'
path "secret/data/itssolutions/db-creds" {
  capabilities = ["read"]
}
path "secret/data/itssolutions/app-config" {
  capabilities = ["read"]
}
POLICY

echo "=== Enabling Kubernetes auth method ==="
vault auth enable kubernetes 2>/dev/null || echo "Kubernetes auth already enabled"

echo "=== Configuring Kubernetes auth ==="
# Read K8s host and CA from inside the cluster via oc
K8S_HOST=$(oc whoami --show-server)
K8S_CA=$(oc -n itssolutions-prod get secret \
  $(oc -n itssolutions-prod get sa backend-sa -o jsonpath='{.secrets[0].name}' 2>/dev/null || echo "default-token") \
  -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d || \
  oc -n vault exec vault-0 -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

# Use vault pod's own service account token to configure kubernetes auth
SA_JWT=$(oc -n vault exec vault-0 -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
SA_CA=$(oc -n vault exec vault-0 -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

vault write auth/kubernetes/config \
  kubernetes_host="${K8S_HOST}" \
  kubernetes_ca_cert="${SA_CA}" \
  token_reviewer_jwt="${SA_JWT}" \
  issuer="https://kubernetes.default.svc.cluster.local"

echo "=== Creating Vault role: itssolutions-backend ==="
vault write auth/kubernetes/role/itssolutions-backend \
  bound_service_account_names=backend-sa \
  bound_service_account_namespaces=itssolutions-prod \
  policies=itssolutions-policy \
  ttl=1h

echo "=== Vault configuration complete ==="
vault kv get secret/itssolutions/db-creds
vault kv get secret/itssolutions/app-config
