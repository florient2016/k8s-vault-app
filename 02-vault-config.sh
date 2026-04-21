#!/usr/bin/env bash
# =============================================================================
# 02-vault-config.sh
# Configures Vault:
#   - Enables KV v2
#   - Stores ALL credentials (PostgreSQL + JWT) inside Vault
#   - Enables Kubernetes auth
#   - Creates policy and role for backend sidecar injection
#
# NO credentials are written to any Kubernetes Secret, ConfigMap or YAML file.
# The ONLY place credentials exist is inside Vault itself.
# PostgreSQL init credentials are injected via a Vault Agent init container.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
log_step()    { echo -e "\n${CYAN}=== $* ===${NC}\n"; }

VAULT_NAMESPACE="vault"
INIT_FILE="/tmp/vault-init.json"

[[ -f "${INIT_FILE}" ]] || \
  log_error "${INIT_FILE} not found — run 01-vault-install.sh first"

ROOT_TOKEN=$(jq -r '.root_token' "${INIT_FILE}")
[[ -n "${ROOT_TOKEN}" ]] || log_error "Empty root token in ${INIT_FILE}"

# Helper: run vault commands inside vault-0 pod
vault_exec() {
  kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- \
    env VAULT_TOKEN="${ROOT_TOKEN}" vault "$@"
}

# =============================================================================
# STEP 1 — Enable KV v2 secrets engine
# =============================================================================
log_step "STEP 1: Enable KV v2 secrets engine"

EXISTING=$(vault_exec secrets list -format=json 2>/dev/null | \
  jq -r 'keys[]' | grep -c "^secret/$" || echo "0")

if [[ "${EXISTING}" -gt 0 ]]; then
  log_warn "KV engine already enabled at secret/ — skipping"
else
  vault_exec secrets enable -path=secret kv-v2
  log_success "KV v2 enabled at path: secret/"
fi

# =============================================================================
# STEP 2 — Store PostgreSQL credentials in Vault
# =============================================================================
log_step "STEP 2: Storing PostgreSQL credentials in Vault"

# Generate a strong random password for PostgreSQL
# This is the ONLY place the password is defined
PG_PASSWORD=$(openssl rand -base64 24 | tr -d '=/+' | head -c 32)
PG_USER="itssolutions"
PG_DATABASE="itssolutions_db"
PG_HOST="postgres.itssolutions-db.svc.cluster.local"
PG_PORT="5432"

vault_exec kv put secret/itssolutions/db-creds \
  host="${PG_HOST}" \
  port="${PG_PORT}" \
  database="${PG_DATABASE}" \
  username="${PG_USER}" \
  password="${PG_PASSWORD}"

log_success "PostgreSQL credentials stored at secret/itssolutions/db-creds"
log_info    "  host     : ${PG_HOST}"
log_info    "  port     : ${PG_PORT}"
log_info    "  database : ${PG_DATABASE}"
log_info    "  username : ${PG_USER}"
log_info    "  password : [stored in Vault only — not shown here]"

# =============================================================================
# STEP 3 — Store app config (JWT secret) in Vault
# =============================================================================
log_step "STEP 3: Storing app config in Vault"

JWT_SECRET=$(openssl rand -base64 48 | tr -d '=/+' | head -c 64)

vault_exec kv put secret/itssolutions/app-config \
  jwt_secret="${JWT_SECRET}"

log_success "App config stored at secret/itssolutions/app-config"
log_info    "  jwt_secret: [stored in Vault only — not shown here]"

# =============================================================================
# STEP 4 — Store PostgreSQL ADMIN credentials for init
# These are used ONLY by the postgres-init Job to bootstrap the DB
# =============================================================================
log_step "STEP 4: Storing PostgreSQL admin/init credentials in Vault"

# The admin password for the postgres superuser (used during DB init only)
PG_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '=/+' | head -c 32)

vault_exec kv put secret/itssolutions/db-init \
  admin_user="postgres" \
  admin_password="${PG_ADMIN_PASSWORD}" \
  app_user="${PG_USER}" \
  app_password="${PG_PASSWORD}" \
  app_database="${PG_DATABASE}"

log_success "PostgreSQL init credentials stored at secret/itssolutions/db-init"

# =============================================================================
# STEP 5 — Create Vault policy
# =============================================================================
log_step "STEP 5: Creating itssolutions-policy"

# Write policy to a temporary file locally
POLICY_FILE=$(mktemp /tmp/itssolutions-policy-XXXXXX.hcl)
cat > "${POLICY_FILE}" <<'EOF'
# Read access to PostgreSQL credentials
path "secret/data/itssolutions/db-creds" {
  capabilities = ["read"]
}

# Read access to app config
path "secret/data/itssolutions/app-config" {
  capabilities = ["read"]
}

# Read access to DB init credentials (used by postgres-init job)
path "secret/data/itssolutions/db-init" {
  capabilities = ["read"]
}
EOF

# Copy the policy file into the Vault pod
kubectl cp "${POLICY_FILE}" vault/vault-0:/tmp/itssolutions-policy.hcl

# Create the policy from the file inside the pod
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" VAULT_ADDR="http://127.0.0.1:8200" \
  vault policy write itssolutions-policy /tmp/itssolutions-policy.hcl

# Cleanup
kubectl exec -n vault vault-0 -- rm -f /tmp/itssolutions-policy.hcl
rm -f "${POLICY_FILE}"

log_success "Policy itssolutions-policy created"

# =============================================================================
# STEP 6 — Enable Kubernetes auth method
# =============================================================================
log_step "STEP 6: Enabling Kubernetes auth method"

AUTH_LIST=$(vault_exec auth list -format=json 2>/dev/null | \
  jq -r 'keys[]' | grep -c "^kubernetes/$" || echo "0")

if [[ "${AUTH_LIST}" -gt 0 ]]; then
  log_warn "Kubernetes auth already enabled — skipping"
else
  vault_exec auth enable kubernetes
  log_success "Kubernetes auth method enabled"
fi

# -----------------------------------------------------------------------------
# Configure Kubernetes auth — use in-cluster service account token
# -----------------------------------------------------------------------------
log_info "Configuring Kubernetes auth..."

# Get Kubernetes API server address from within the cluster
K8S_HOST=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- \
  sh -c 'echo $KUBERNETES_SERVICE_HOST')
K8S_PORT=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- \
  sh -c 'echo $KUBERNETES_SERVICE_PORT')

vault_exec write auth/kubernetes/config \
  kubernetes_host="https://${K8S_HOST}:${K8S_PORT}" \
  token_reviewer_jwt="@/var/run/secrets/kubernetes.io/serviceaccount/token" \
  kubernetes_ca_cert="@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" \
  issuer="https://kubernetes.default.svc.cluster.local"

log_success "Kubernetes auth configured"

# =============================================================================
# STEP 7 — Create Vault role for backend
# =============================================================================
log_step "STEP 7: Creating Vault role itssolutions-backend"

vault_exec write auth/kubernetes/role/itssolutions-backend \
  bound_service_account_names=backend-sa \
  bound_service_account_namespaces=itssolutions-prod \
  policies=itssolutions-policy \
  ttl=1h \
  max_ttl=24h

log_success "Vault role itssolutions-backend created"
log_info    "  ServiceAccount : backend-sa"
log_info    "  Namespace      : itssolutions-prod"
log_info    "  Policy         : itssolutions-policy"

# =============================================================================
# STEP 8 — Create Vault role for postgres-init job
# =============================================================================
log_step "STEP 8: Creating Vault role itssolutions-db-init"

vault_exec write auth/kubernetes/role/itssolutions-db-init \
  bound_service_account_names=postgres-init-sa \
  bound_service_account_namespaces=itssolutions-db \
  policies=itssolutions-policy \
  ttl=15m \
  max_ttl=30m

log_success "Vault role itssolutions-db-init created"
log_info    "  ServiceAccount : postgres-init-sa"
log_info    "  Namespace      : itssolutions-db"
log_info    "  Policy         : itssolutions-policy"

# =============================================================================
# STEP 9 — Verify all secrets are stored correctly
# =============================================================================
log_step "STEP 9: Verifying Vault secrets"

log_info "Verifying secret/itssolutions/db-creds..."
vault_exec kv get -format=json secret/itssolutions/db-creds | \
  jq '.data.data | keys'

log_info "Verifying secret/itssolutions/app-config..."
vault_exec kv get -format=json secret/itssolutions/app-config | \
  jq '.data.data | keys'

log_info "Verifying secret/itssolutions/db-init..."
vault_exec kv get -format=json secret/itssolutions/db-init | \
  jq '.data.data | keys'

log_success "All secrets verified (keys only shown — values are in Vault)"

# =============================================================================
# Summary
# =============================================================================
echo ""
log_success "============================================"
log_success " Vault configuration complete"
log_success "============================================"
echo ""
echo -e "  Secrets stored in Vault:"
echo -e "    ${CYAN}secret/itssolutions/db-creds${NC}   — PostgreSQL connection credentials"
echo -e "    ${CYAN}secret/itssolutions/app-config${NC} — JWT secret"
echo -e "    ${CYAN}secret/itssolutions/db-init${NC}    — PostgreSQL admin/init credentials"
echo ""
echo -e "  Vault roles:"
echo -e "    ${CYAN}itssolutions-backend${NC}  — backend-sa in itssolutions-prod"
echo -e "    ${CYAN}itssolutions-db-init${NC}  — postgres-init-sa in itssolutions-db"
echo ""
echo -e "  ${YELLOW}No credentials were written to any Kubernetes Secret or YAML file.${NC}"
echo -e "  ${YELLOW}All credentials exist exclusively inside Vault.${NC}"
echo ""
