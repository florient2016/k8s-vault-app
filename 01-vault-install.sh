#!/usr/bin/env bash
# =============================================================================
# 01-vault-install.sh
# Installs HashiCorp Vault via Helm using local-storage StorageClass
# Exports ROOT_TOKEN to environment for retrieval
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

# Ensure cleanup on exit
cleanup() {
  if [[ -f "${INIT_FILE}" ]]; then
    chmod 600 "${INIT_FILE}"
  fi
}
trap cleanup EXIT

# Prerequisites
for cmd in helm kubectl jq python3; do
  command -v "$cmd" &>/dev/null || log_error "Required tool not found: $cmd"
done

VAULT_NAMESPACE="vault"
VAULT_RELEASE="vault"
INIT_FILE="/tmp/vault-init.json"
VAULT_ENV_FILE="${HOME}/.vault-env"

# =============================================================================
# Step 1 — Helm repo
# =============================================================================
log_step "Adding HashiCorp Helm repository"
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update > /dev/null
log_success "Helm repo ready"

# =============================================================================
# Step 2 — Install Vault
# =============================================================================
log_step "Installing Vault in namespace '${VAULT_NAMESPACE}'"

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

# =============================================================================
# Step 3 — Wait for vault-0 pod Running
# =============================================================================
log_step "Waiting for vault-0 pod to reach Running state (up to 5 min)"

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
  
  if (( i % 3 == 0 )); then
    log_warn "Attempt ${i}/60 — Pod: ${POD_PHASE} | PVCs: ${PVC_STATUS}"
  fi
  sleep 5
done

POD_PHASE=$(kubectl get pod vault-0 -n "${VAULT_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
[[ "${POD_PHASE}" == "Running" ]] || \
  log_error "vault-0 not Running after 5 min (current: ${POD_PHASE})"

# =============================================================================
# Step 4 — Initialize and Unseal Vault
# =============================================================================
log_step "Initializing and unsealing Vault"

# Check if Vault is already initialized
INITIALIZED=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- \
  vault status -format=json 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('initialized', False))" 2>/dev/null || echo "false")

if [[ "${INITIALIZED}" == "true" ]]; then
  log_warn "Vault is already initialized"

  if [[ -f "${INIT_FILE}" ]]; then
    log_info "Found existing init file at ${INIT_FILE}"
  else
    log_error "Vault is initialized but ${INIT_FILE} not found"
    log_error "Cannot proceed without unseal keys"
    exit 1
  fi
else
  log_info "Initializing Vault (1 key share, threshold 1)..."
  kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- \
    vault operator init -key-shares=1 -key-threshold=1 -format=json \
    > "${INIT_FILE}"
  
  chmod 600 "${INIT_FILE}"
  log_success "Vault initialized — credentials saved to ${INIT_FILE}"
fi

# Extract unseal key and root token
UNSEAL_KEY=$(python3 -c "import json; d=json.load(open('${INIT_FILE}')); print(d['unseal_keys_b64'][0])")
ROOT_TOKEN=$(python3 -c "import json; d=json.load(open('${INIT_FILE}')); print(d['root_token'])")

# Check if Vault is sealed
SEALED=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- \
  vault status -format=json 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed', True))" 2>/dev/null || echo "true")

if [[ "${SEALED}" == "true" ]]; then
  log_info "Unsealing Vault..."
  kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- \
    vault operator unseal "${UNSEAL_KEY}" > /dev/null
  log_success "Vault unsealed"
else
  log_info "Vault is already unsealed"
fi

# =============================================================================
# Step 5 — Verify
# =============================================================================
log_step "Verifying Vault status"
kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- vault status

# =============================================================================
# Step 6 — Export credentials to environment
# =============================================================================
log_step "Saving credentials to environment"

# Export to current shell environment (for immediate use)
export ROOT_TOKEN
export UNSEAL_KEY
export VAULT_NAMESPACE
export VAULT_RELEASE
export INIT_FILE

# Save to file for persistence across shells
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

chmod 600 "${VAULT_ENV_FILE}"

# =============================================================================
# Summary
# =============================================================================
echo ""
log_success "╔════════════════════════════════════════════════════════╗"
log_success "║        VAULT INSTALLATION COMPLETE                    ║"
log_success "╚════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}Environment File${NC}:    ${VAULT_ENV_FILE}"
echo -e "  ${GREEN}Init File${NC}:           ${INIT_FILE}"
echo -e "  ${GREEN}Namespace${NC}:          ${VAULT_NAMESPACE}"
echo -e "  ${GREEN}Pod Status${NC}:         Running ✓"
echo ""
log_success "Current shell environment variables:"
echo -e "  ${YELLOW}ROOT_TOKEN${NC}:          ${ROOT_TOKEN:0:20}…"
echo -e "  ${YELLOW}UNSEAL_KEY${NC}:         ${UNSEAL_KEY:0:20}…"
echo -e "  ${YELLOW}INIT_FILE${NC}:          ${INIT_FILE}"
echo ""
log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_warn "IMPORTANT SECURITY NOTES:"
log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  1. Keep ${INIT_FILE} in a SECURE location"
echo "     (chmod 600 — readable only by you)"
echo ""
echo "  2. Root token is available in current shell:"
echo "     echo \$ROOT_TOKEN"
echo ""
echo "  3. To source credentials in another shell:"
echo "     source ${VAULT_ENV_FILE}"
echo ""
echo "  4. Vault UI available at: http://localhost:8200"
echo "     (After: kubectl port-forward -n vault svc/vault 8200:8200)"
echo ""
echo "  5. To access vault CLI inside cluster:"
echo "     kubectl exec -n ${VAULT_NAMESPACE} vault-0 -- vault login \${ROOT_TOKEN}"
echo ""
log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Verify exported variables
log_info "Verifying exported variables..."
[[ -n "${ROOT_TOKEN}" ]] && log_success "✓ ROOT_TOKEN exported" || log_error "ROOT_TOKEN not set"
[[ -n "${UNSEAL_KEY}" ]] && log_success "✓ UNSEAL_KEY exported" || log_error "UNSEAL_KEY not set"
[[ -f "${VAULT_ENV_FILE}" ]] && log_success "✓ Credentials file created: ${VAULT_ENV_FILE}" || log_error "Env file not created"

echo ""
log_success "All systems ready!"
