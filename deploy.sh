#!/usr/bin/env bash
# =============================================================================
# deploy.sh
# Full automated deployment — applies all manifests in order
# Handles local-storage PV/PVC + Vault + PostgreSQL + Backend + Frontend
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colors and logging
# -----------------------------------------------------------------------------
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Prereqs
# -----------------------------------------------------------------------------
for cmd in kubectl helm jq; do
  command -v "$cmd" &>/dev/null || log_error "Required tool not found: $cmd"
done

# Use oc if available (OpenShift), fall back to kubectl
OC=$(command -v oc 2>/dev/null || echo "kubectl")
log_info "Using CLI: ${OC}"

# =============================================================================
# STEP 0 — Detect node names for PV nodeAffinity
# =============================================================================
log_step "STEP 0: Detecting cluster nodes"

NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
NODE_COUNT=${#NODES[@]}
log_info "Found ${NODE_COUNT} node(s): ${NODES[*]}"

if [[ ${NODE_COUNT} -lt 1 ]]; then
  log_error "No nodes found in cluster"
fi

# Assign nodes for PVs (if only 1 node available, use it for both)
VAULT_NODE="${NODES[0]}"
POSTGRES_NODE="${NODES[$(( NODE_COUNT > 1 ? 1 : 0 ))]}"

log_info "Vault PV    → node: ${VAULT_NODE}"
log_info "Postgres PV → node: ${POSTGRES_NODE}"

# =============================================================================
# STEP 1 — Create host directories on nodes
# =============================================================================
log_step "STEP 1: Preparing host directories via privileged DaemonSet"

# We create a short-lived Job per node to mkdir the host paths
# This avoids needing SSH access to the nodes

for NODE in "${VAULT_NODE}" "${POSTGRES_NODE}"; do
  if [[ "${NODE}" == "${VAULT_NODE}" ]]; then
    DIR="/mnt/tampon/vault"
    JOB_NAME="mkdir-vault"
  else
    DIR="/mnt/tampon/postgres"
    JOB_NAME="mkdir-postgres"
  fi

  log_info "Creating ${DIR} on node ${NODE}..."

  # Delete previous job if exists
  kubectl delete job "${JOB_NAME}" --ignore-not-found=true -n kube-system

  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: kube-system
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: OnFailure
      nodeSelector:
        kubernetes.io/hostname: ${NODE}
      tolerations:
        - operator: Exists
      hostPID: true
      containers:
        - name: mkdir
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              mkdir -p ${DIR}
              chmod 777 ${DIR}
              echo "Directory ${DIR} ready on node ${NODE}"
          securityContext:
            privileged: true
          volumeMounts:
            - name: host-root
              mountPath: /mnt/host
      volumes:
        - name: host-root
          hostPath:
            path: /
            type: Directory
EOF

  # Wait for job to complete
  log_info "Waiting for job ${JOB_NAME} to complete..."
  kubectl wait --for=condition=complete job/"${JOB_NAME}" \
    -n kube-system --timeout=60s || \
    log_warn "Job ${JOB_NAME} did not complete in time — continuing anyway"
done

log_success "Host directories prepared"

# =============================================================================
# STEP 2 — Apply storage (StorageClass + PVs) with correct node names
# =============================================================================
log_step "STEP 2: Applying StorageClass and PersistentVolumes"

# Patch 00-storage.yaml with actual node names
STORAGE_FILE="${SCRIPT_DIR}/00-storage.yaml"
STORAGE_TMP=$(mktemp /tmp/storage-XXXXX.yaml)

sed \
  -e "s/worker-0/${VAULT_NODE}/g" \
  -e "s/worker-1/${POSTGRES_NODE}/g" \
  "${STORAGE_FILE}" > "${STORAGE_TMP}"

kubectl apply -f "${STORAGE_TMP}"
rm -f "${STORAGE_TMP}"
log_success "StorageClass and PVs applied"

# =============================================================================
# STEP 3 — Create namespaces
# =============================================================================
log_step "STEP 3: Creating namespaces"
kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
log_success "Namespaces created"

# Apply SCC for OpenShift if oc is available
if command -v oc &>/dev/null; then
  log_info "OpenShift detected — applying anyuid SCC..."
  oc adm policy add-scc-to-user anyuid \
    system:serviceaccount:itssolutions-db:default 2>/dev/null || true
  oc adm policy add-scc-to-user anyuid \
    system:serviceaccount:itssolutions-prod:backend-sa 2>/dev/null || true
  oc adm policy add-scc-to-user anyuid \
    system:serviceaccount:vault:vault 2>/dev/null || true
  log_success "SCC applied"
fi

# =============================================================================
# STEP 4 — Install Vault
# =============================================================================
log_step "STEP 4: Installing HashiCorp Vault"
chmod +x "${SCRIPT_DIR}/01-vault-install.sh"
"${SCRIPT_DIR}/01-vault-install.sh"
log_success "Vault installed and initialized"

# =============================================================================
# STEP 5 — Configure Vault
# =============================================================================
log_step "STEP 5: Configuring Vault secrets, policies and Kubernetes auth"
chmod +x "${SCRIPT_DIR}/02-vault-config.sh"
"${SCRIPT_DIR}/02-vault-config.sh"
log_success "Vault configured"

# =============================================================================
# STEP 6 — Deploy PostgreSQL
# =============================================================================
log_step "STEP 6: Deploying PostgreSQL"
kubectl apply -f "${SCRIPT_DIR}/03-postgres.yaml"

log_info "Waiting for PostgreSQL PVC to be bound..."
for i in $(seq 1 30); do
  PVC_STATUS=$(kubectl get pvc postgres-pvc -n itssolutions-db \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  if [[ "${PVC_STATUS}" == "Bound" ]]; then
    log_success "PostgreSQL PVC is Bound"
    break
  fi
  log_warn "Attempt ${i}/30 — PVC status: ${PVC_STATUS}"
  sleep 5
done

log_info "Waiting for PostgreSQL pod to be Ready..."
kubectl rollout status deployment/postgres \
  -n itssolutions-db --timeout=180s
log_success "PostgreSQL is ready"

# =============================================================================
# STEP 7 — Deploy Backend
# =============================================================================
log_step "STEP 7: Deploying Backend (2 replicas)"
kubectl apply -f "${SCRIPT_DIR}/04-backend.yaml"

log_info "Waiting for backend pods to be Ready (Vault sidecar injection takes ~60s)..."
kubectl rollout status deployment/backend \
  -n itssolutions-prod --timeout=300s
log_success "Backend is ready"

# =============================================================================
# STEP 8 — Deploy Frontend
# =============================================================================
log_step "STEP 8: Deploying Frontend"
kubectl apply -f "${SCRIPT_DIR}/05-frontend.yaml"
kubectl rollout status deployment/frontend \
  -n itssolutions-prod --timeout=120s
log_success "Frontend is ready"

# =============================================================================
# STEP 9 — Apply Routes
# =============================================================================
log_step "STEP 9: Applying TLS Routes"
kubectl apply -f "${SCRIPT_DIR}/06-routes.yaml"
log_success "Routes applied"

# =============================================================================
# FINAL — Print summary
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  DEPLOYMENT COMPLETE${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

# Get frontend URL
if command -v oc &>/dev/null; then
  FRONTEND_HOST=$(oc get route frontend \
    -n itssolutions-prod \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "route-not-found")
  FRONTEND_URL="https://${FRONTEND_HOST}"
else
  FRONTEND_SVC=$(kubectl get svc frontend \
    -n itssolutions-prod \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "pending")
  FRONTEND_URL="http://${FRONTEND_SVC}:8080"
fi

echo -e "  ${CYAN}Frontend URL  :${NC} ${FRONTEND_URL}"
echo -e "  ${CYAN}Default user  :${NC} admin"
echo -e "  ${CYAN}Default pass  :${NC} Admin@1234!"
echo ""
echo -e "  ${YELLOW}Storage nodes :${NC}"
echo -e "    Vault PV    → ${VAULT_NODE}   (/mnt/tampon/vault)"
echo -e "    Postgres PV → ${POSTGRES_NODE}  (/mnt/tampon/postgres)"
echo ""
echo -e "  ${YELLOW}Vault init file:${NC} /tmp/vault-init.json"
echo -e "${GREEN}============================================================${NC}"
echo ""
