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

VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('/tmp/vault-init.json'))['root_token'])")

kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" \
  vault write auth/kubernetes/role/itssolutions-db-init \
    bound_service_account_names=postgres-sa \
    bound_service_account_namespaces=itssolutions-db \
    policies=itssolutions-policy \
    ttl=1h \
    max_ttl=24h

log_info "Waiting for PostgreSQL to be ready (up to 5 min)..."
kubectl rollout status deployment/postgres \
  -n itssolutions-db \
  --timeout=300s
log_success "PostgreSQL is ready"

# =============================================================================
# Step 6 — Deploy Backend
# =============================================================================
# Step 6 — Deploy Backend

log_step "STEP 6: Deploying Backend"


kubectl apply -f "${SCRIPT_DIR}/04-backend.yaml"

sleep 40

# Get the password from Vault secrets file
DB_PASS=$(kubectl exec -n itssolutions-prod \
  $(kubectl get pod -n itssolutions-prod -l app=backend -o jsonpath='{.items[0].metadata.name}') \
  -c vault-agent -- cat /vault/secrets/db-creds | grep DB_PASSWORD | cut -d'"' -f2)

#echo "Password from Vault: $DB_PASS"

# Create user, database, and grant privileges
kubectl exec -n itssolutions-db \
  $(kubectl get pod -n itssolutions-db -l app=postgres -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U postgres <<EOF
CREATE USER itssolutions WITH PASSWORD '$DB_PASS';
CREATE DATABASE itssolutions_db OWNER itssolutions;
GRANT ALL PRIVILEGES ON DATABASE itssolutions_db TO itssolutions;
EOF

POSTGRES_POD=$(kubectl get pod -n itssolutions-db -l app=postgres -o jsonpath='{.items[0].metadata.name}')

# Create the user
#kubectl exec -n itssolutions-db $POSTGRES_POD \
#  -- psql -U postgres -c "CREATE USER itssolutions WITH PASSWORD '$DB_PASS';"

# Grant privileges
kubectl exec -n itssolutions-db $POSTGRES_POD \
  -- psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE itssolutions_db TO itssolutions;"

POSTGRES_POD=$(kubectl get pod -n itssolutions-db -l app=postgres -o jsonpath='{.items[0].metadata.name}')

# Grant schema permissions
kubectl exec -n itssolutions-db $POSTGRES_POD \
  -- psql -U postgres -d itssolutions_db -c "GRANT ALL ON SCHEMA public TO itssolutions;"

# Grant on all existing tables
kubectl exec -n itssolutions-db $POSTGRES_POD \
  -- psql -U postgres -d itssolutions_db -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO itssolutions;"

# Grant on all sequences (needed for auto-increment/serial columns)
kubectl exec -n itssolutions-db $POSTGRES_POD \
  -- psql -U postgres -d itssolutions_db -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO itssolutions;"

# Set default privileges for future objects
kubectl exec -n itssolutions-db $POSTGRES_POD \
  -- psql -U postgres -d itssolutions_db -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO itssolutions;"

kubectl exec -n itssolutions-db $POSTGRES_POD \
  -- psql -U postgres -d itssolutions_db -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO itssolutions;"

# Make itssolutions the schema owner to avoid future issues
kubectl exec -n itssolutions-db $POSTGRES_POD \
  -- psql -U postgres -d itssolutions_db -c "ALTER SCHEMA public OWNER TO itssolutions;"


# Verify user exists with password this time
kubectl exec -n itssolutions-db $POSTGRES_POD \
  -- psql -U postgres -c "SELECT usename, passwd FROM pg_shadow WHERE usename='itssolutions';"

# Test login
kubectl exec -n itssolutions-db $POSTGRES_POD \
  -- psql -U itssolutions -d itssolutions_db -c "SELECT current_user, current_database();"

# Extract password from vault-agent secret file
DB_PASS=$(kubectl exec -n itssolutions-prod \
  $(kubectl get pod -n itssolutions-prod -l app=backend -o jsonpath='{.items[0].metadata.name}') \
  -c vault-agent -- cat /vault/secrets/db-creds | grep DB_PASSWORD | cut -d'"' -f2)

# Set PostgreSQL password to exactly match Vault
kubectl exec -n itssolutions-db $POSTGRES_POD \
  -- psql -U postgres -c "ALTER USER itssolutions WITH PASSWORD '$DB_PASS';"


kubectl rollout restart deployment/backend -n itssolutions-prod

#log_info "Waiting for Backend to be ready (up to 10 min — npm install on first start)..."
kubectl rollout status deployment/backend \
  -n itssolutions-prod \
  --timeout=600s

log_success "Backend is ready"

# Show pod status
kubectl get pods -n itssolutions-prod -l app=backend

# Get a pod name
BACKEND_POD=$(kubectl get pod -n itssolutions-prod -l app=backend \
  -o jsonpath='{.items[0].metadata.name}')

# Show backend logs
log_info "Backend logs:"
kubectl logs -n itssolutions-prod "${BACKEND_POD}" -c backend --tail=30

# Confirm secrets present
log_info "Injected secret files:"
kubectl exec -n itssolutions-prod "${BACKEND_POD}" -c backend -- \
  ls -la /vault/secrets/

log_success "Step 6 complete"


# =============================================================================
# Step 7 — Deploy Frontend
# =============================================================================
log_step "STEP 7: Deploying Frontend"
kubectl apply -f "${SCRIPT_DIR}/05-frontend.yaml"

sleep 40

kubectl patch deployment frontend -n itssolutions-prod --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {"name": "nginx-tmp", "emptyDir": {}}
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {"name": "nginx-conf-d", "emptyDir": {}}
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {"name": "nginx-tmp", "mountPath": "/tmp"}
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {"name": "nginx-conf-d", "mountPath": "/etc/nginx/conf.d"}
  }
]'


log_info "Waiting for Frontend to be ready (up to 3 min)..."
kubectl rollout status deployment/frontend \
  -n itssolutions-prod \
  --timeout=180s
log_success "Frontend is ready"

# =============================================================================
# Step 8 — Apply Routes / Ingress
# =============================================================================
#log_step "STEP 8: Applying Routes"
#kubectl apply -f "${SCRIPT_DIR}/06-routes.yaml"
#log_success "Routes applied"

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
