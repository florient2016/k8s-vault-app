#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================="
echo " ITS Solutions - OpenShift Deployment Script"
echo "=============================================="

# Check prerequisites
command -v oc >/dev/null 2>&1 || { echo "ERROR: 'oc' CLI not found. Please install OpenShift CLI."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "ERROR: 'helm' CLI not found. Please install Helm."; exit 1; }

echo ""
echo "=== Checking OpenShift login status ==="
oc whoami || { echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."; exit 1; }
echo "Logged in as: $(oc whoami)"
echo "Server: $(oc whoami --show-server)"

echo ""
echo "=== [Step 1] Creating Namespaces ==="
oc apply -f 00-namespace.yaml
echo "Namespaces created."

echo ""
echo "=== [Step 2] Adding SCC anyuid to ServiceAccounts ==="
# Grant anyuid SCC to service accounts for PostgreSQL and frontend/backend
oc adm policy add-scc-to-user anyuid -z postgres-sa -n itssolutions-db --as system:admin 2>/dev/null || \
  oc adm policy add-scc-to-user anyuid -z postgres-sa -n itssolutions-db || true
oc adm policy add-scc-to-user anyuid -z backend-sa -n itssolutions-prod --as system:admin 2>/dev/null || \
  oc adm policy add-scc-to-user anyuid -z backend-sa -n itssolutions-prod || true
oc adm policy add-scc-to-user anyuid -z frontend-sa -n itssolutions-prod --as system:admin 2>/dev/null || \
  oc adm policy add-scc-to-user anyuid -z frontend-sa -n itssolutions-prod || true
echo "SCC anyuid granted."

echo ""
echo "=== [Step 3] Installing HashiCorp Vault ==="
bash 01-vault-install.sh

echo ""
echo "=== [Step 4] Deploying PostgreSQL ==="
oc apply -f 03-postgres.yaml

echo ""
echo "=== Waiting for PostgreSQL pod to be ready ==="
oc -n itssolutions-db rollout status deployment/postgres --timeout=300s
echo "PostgreSQL is ready."

echo ""
echo "=== [Step 5] Configuring Vault ==="
bash 02-vault-config.sh

echo ""
echo "=== [Step 6] Deploying Backend ==="
oc apply -f 04-backend.yaml

echo ""
echo "=== Waiting for Backend pods to be ready ==="
oc -n itssolutions-prod rollout status deployment/backend --timeout=300s
echo "Backend is ready."

echo ""
echo "=== [Step 7] Deploying Frontend ==="
oc apply -f 05-frontend.yaml
oc -n itssolutions-prod rollout status deployment/frontend --timeout=180s
echo "Frontend is ready."

echo ""
echo "=== [Step 8] Creating Routes ==="
oc apply -f 06-routes.yaml

echo ""
echo "=============================================="
echo " Deployment Complete!"
echo "=============================================="
echo ""

# Print frontend URL
FRONTEND_URL=$(oc -n itssolutions-prod get route frontend-route -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$FRONTEND_URL" ]; then
  echo "  Frontend URL : https://${FRONTEND_URL}"
else
  echo "  Frontend URL : (route host not yet assigned - check: oc -n itssolutions-prod get route frontend-route)"
fi

BACKEND_URL=$(oc -n itssolutions-prod get route backend-route -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$BACKEND_URL" ]; then
  echo "  Backend URL  : https://${BACKEND_URL}/api/health"
fi

echo ""
echo "  Default credentials: admin / Admin@1234!"
echo ""
echo "  Namespaces:"
echo "    - itssolutions-db   (PostgreSQL)"
echo "    - itssolutions-prod (Frontend + Backend)"
echo "    - vault             (HashiCorp Vault)"
echo ""
echo "  Vault keys saved to: vault-keys.txt (KEEP SECURE!)"
echo "=============================================="
