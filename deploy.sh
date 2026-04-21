#!/usr/bin/env bash
# =============================================================================
# deploy.sh
# Full deployment script
# Assumes local storage already exists on worker1 and worker2
# No auto-patching of node names needed
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
log_step()    { echo -e "\n${CYAN}==============================${NC}"; \
                echo -e "${CYAN} $* ${NC}"; \
                echo -e "${CYAN}==============================${NC}\n"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# =============================================================================
# Step 1 — Namespaces
# =============================================================================
log_step "STEP 1: Creating namespaces"
kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
log_success "Namespaces created"

# =============================================================================
# Step 2 — StorageClass and PersistentVolumes
# =============================================================================
log_step "STEP 2: Applying StorageClass and PersistentVolumes"
kubectl apply -f "${SCRIPT_DIR}/00-storage.yaml"

# Wait for PVs to be Available
log_info "Waiting for PVs to become Available..."
for PV in vault-pv postgres-pv; do
  for i in $(seq 1 20); do
    PV_STATUS=$(kubectl get pv "${PV}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    if [[ "${PV_STATUS}" == "Available" ]]; then
      log_success "PV ${PV}: Available"
      break
    fi
    log_warn "PV ${PV}: ${PV_STATUS} — waiting... (${i}/20)"
    sleep 3
  done
done

# =============================================================================
# Step 3 — Install Vault
# =============================================================================
log_step "STEP 3: Installing Vault"
chmod +x "${SCRIPT_DIR}/01-vault-install.sh"
"${SCRIPT_DIR}/01-vault-install.sh"

# =============================================================================
# Step 4 — Configure Vault (store all credentials)
# =============================================================================
log_step "STEP 4: Configuring Vault and storing all credentials"
chmod +x "${SCRIPT_DIR}/02-vault-config.sh"
"${SCRIPT_DIR}/02-vault-config.sh"

# =============================================================================
# Step 5 — Deploy PostgreSQL
# =============================================================================
log_step "STEP 5: Deploying PostgreSQL"
kubectl apply -f "${SCRIPT_DIR}/03-postgres.yaml"

log_info "Waiting for PostgreSQL to be ready (up to 5 min)..."
kubectl rollout status deployment/postgres \
  -n itssolutions-db \
  --timeout=300s
log_success "PostgreSQL is ready"

# =============================================================================
# Step 6 — Deploy Backend
# =============================================================================
log_step "STEP 6: Deploying Backend"
kubectl apply -f "${SCRIPT_DIR}/04-backend.yaml"

log_info "Waiting for Backend to be ready (up to 5 min)..."
kubectl rollout status deployment/backend \
  -n itssolutions-prod \
  --timeout=300s
log_success "Backend is ready"

# =============================================================================
# Step 7 — Deploy Frontend
# =============================================================================
log_step "STEP 7: Deploying Frontend"
kubectl apply -f "${SCRIPT_DIR}/05-frontend.yaml"

log_info "Waiting for Frontend to be ready (up to 3 min)..."
kubectl rollout status deployment/frontend \
  -n itssolutions-prod \
  --timeout=180s
log_success "Frontend is ready"

# =============================================================================
# Step 8 — Apply Routes / Ingress
# =============================================================================
log_step "STEP 8: Applying Routes"
kubectl apply -f "${SCRIPT_DIR}/06-routes.yaml"
log_success "Routes applied"

# =============================================================================
# Final Summary
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  DEPLOYMENT COMPLETE${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  ${CYAN}Namespaces:${NC}"
kubectl get namespaces | grep -E "itssolutions|vault"
echo ""
echo -e "  ${CYAN}PersistentVolumes:${NC}"
kubectl get pv vault-pv postgres-pv
echo ""
echo -e "  ${CYAN}PersistentVolumeClaims:${NC}"
kubectl get pvc -n vault
kubectl get pvc -n itssolutions-db
echo ""
echo -e "  ${CYAN}Pods:${NC}"
kubectl get pods -n vault
kubectl get pods -n itssolutions-db
kubectl get pods -n itssolutions-prod
echo ""
echo -e "  ${CYAN}Services:${NC}"
kubectl get svc -n itssolutions-prod
echo ""
echo -e "  ${YELLOW}Default login credentials:${NC}"
echo -e "    Username : admin"
echo -e "    Password : Admin@1234!"
echo ""
echo -e "  ${YELLOW}All other credentials are stored exclusively in Vault.${NC}"
echo -e "${GREEN}============================================================${NC}"
