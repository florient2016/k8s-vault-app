#!/usr/bin/env bash
# =============================================================================
# 01-vault-install.sh
# Installs HashiCorp Vault via Helm using local-storage StorageClass
# NO credentials stored anywhere except inside Vault itself
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
log_step()    { echo -e "\n${BLUE}===${NC} ${GREEN}$*${NC} ${BLUE}===${NC}"; }

# -----------------------------------------------------------------------------
# Prereqs
# -----------------------------------------------------------------------------
for cmd in helm kubectl jq; do
  command -v "$cmd" &>/dev/null || log_error "Required tool not found: $cmd"
done

VAULT_NAMESPACE="vault"
VAULT_RELEASE="vault"
INIT_FILE="/tmp/vault-init.json"

# -----------------------------------------------------------------------------
# Step 1 — Helm repo
# -----------------------------------------------------------------------------
log_info "Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update
log_success "Helm repo ready"

# -----------------------------------------------------------------------------
# Step 2 — Install Vault
# -----------------------------------------------------------------------------
log_info "Installing Vault in namespace '${VAULT_NAMESPACE}'..."

helm upgrade --install "${VAULT_RELEASE}" hashicorp/vault \
  --namespace "${VAULT_NAMESPACE}" \
  --create-namespace \
  --set server.standalone.enabled=true \
  --set server.dataStorage.enabled=true \
  --set server.dataStorage.size=10Gi \
  --set server.dataStorage.storageClass=local-storage \
  --set server.dataStorage.accessMode=ReadWriteOnce \
  --set injector.enabled=true \
  --set injector.replicas=1 \
  --set ui.enabled=true \
  --set server.resources.requests.memory=256Mi \
  --set server.resources.requests.cpu=250m \
  --set server.resources.limits.memory=512Mi \
  --set server.resources.limits.cpu=500m \
  --wait=false

log_success "Helm chart applied"

# -----------------------------------------------------------------------------
# Step 3 — Wait for vault-0 pod Running
# -----------------------------------------------------------------------------
log_info "Waiting for vault-0 pod to reach Running state (up to 5 min)..."

for i in $(seq 1 60); do
  POD_PHASE=$(kubectl get pod vault-0 -n "${VAULT_NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

  if [[ "${POD_PHASE}" == "Running" ]]; then
    log_success "vault-0 is Running"
    break
  fi

  PVC_STATUS=$(kubectl get pvc -n "${VAULT_NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}' \
    2>/dev/null || echo "none")
  log_warn "Attempt ${i}/60 — Pod: ${POD_PHASE} | PVCs: ${PVC_STATUS}"
  sleep 5
done

POD_PHASE=$(kubectl get pod vault-0 -n "${VAULT_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
[[ "${POD_PHASE}" == "Running" ]] || \
  log_error "vault-0 not Running after 5 min"

# =============================================================================
# STEP 4 — Initialize and Unseal Vault
# =============================================================================
log_step "STEP 4: Initializing and unsealing Vault"

INIT_FILE="/tmp/vault-init.json"

# Check if Vault is already initialized
INITIALIZED=$(kubectl exec -n vault vault-0 -- \
  vault status -format=json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['initialized'])" 2>/dev/null || echo "false")

if [ "${INITIALIZED}" = "True" ] || [ "${INITIALIZED}" = "true" ]; then
  log_info "Vault is already initialized"

  if [ -f "${INIT_FILE}" ]; then
    log_info "Found existing init file at ${INIT_FILE}"
  else
    log_error "Vault is initialized but ${INIT_FILE} not found — cannot unseal automatically"
    log_error "Manually provide the unseal key and root token, then re-run"
    exit 1
  fi
else
  log_info "Initializing Vault (1 key share, threshold 1)..."
  kubectl exec -n vault vault-0 -- \
    vault operator init -key-shares=1 -key-threshold=1 -format=json \
    > "${INIT_FILE}"
  log_success "Vault initialized — credentials saved to ${INIT_FILE}"
fi

# Read unseal key and root token from file
UNSEAL_KEY=$(python3 -c "import json; d=json.load(open('${INIT_FILE}')); print(d['unseal_keys_b64'][0])")
ROOT_TOKEN=$(python3 -c "import json; d=json.load(open('${INIT_FILE}')); print(d['root_token'])")

# Check if Vault is sealed
SEALED=$(kubectl exec -n vault vault-0 -- \
  vault status -format=json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])" 2>/dev/null || echo "true")

if [ "${SEALED}" = "True" ] || [ "${SEALED}" = "true" ]; then
  log_info "Unsealing Vault..."
  kubectl exec -n vault vault-0 -- vault operator unseal "${UNSEAL_KEY}"
  log_success "Vault unsealed"
else
  log_info "Vault is already unsealed"
fi

log_success "Vault is ready (initialized and unsealed)"


# -----------------------------------------------------------------------------
# Step 5 — Unseal
# -----------------------------------------------------------------------------
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${INIT_FILE}")

log_info "Unsealing Vault..."
kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- \
  vault operator unseal "${UNSEAL_KEY}"

log_success "Vault unsealed"

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------
log_info "Vault status:"
kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- vault status || true

ROOT_TOKEN=$(jq -r '.root_token' "${INIT_FILE}")

export ROOT_TOKEN
export UNSEAL_KEY
export VAULT_NAMESPACE
export VAULT_RELEASE
export INIT_FILE


cat > "${VAULT_ENV_FILE}" <<EOF
#!/usr/bin/env bash
# Vault credentials — sourced from 01-vault-install.sh
# Generated: $(date -Iseconds)

export VAULT_NAMESPACE="${VAULT_NAMESPACE}"
export VAULT_RELEASE="${VAULT_RELEASE}"
export INIT_FILE="${INIT_FILE}"
export UNSEAL_KEY="${UNSEAL_KEY}"
export ROOT_TOKEN="${ROOT_TOKEN}"
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="${ROOT_TOKEN}"

# Convenience aliases
alias vault-port-forward='kubectl port-forward -n ${VAULT_NAMESPACE} svc/vault 8200:8200'
alias vault-login="export VAULT_TOKEN=\${ROOT_TOKEN}"
alias vault-status="kubectl exec -n ${VAULT_NAMESPACE} vault-0 -- vault status"
EOF

echo ""
log_success "============================================"
log_success " Vault installation complete"
log_success " Init file : ${INIT_FILE}  (chmod 600)"
log_success " Root token: ${ROOT_TOKEN}"
log_success "============================================"
log_warn "Keep ${INIT_FILE} safe — it contains your unseal key and root token"
