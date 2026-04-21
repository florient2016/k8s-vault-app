#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║        ITSSolutions – Full Stack Kubernetes Deploy       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Helper ─────────────────────────────────────────────────────────────────────
wait_for_deployment() {
  local namespace="$1"
  local deployment="$2"
  local timeout="${3:-300s}"
  echo "  ⏳  Waiting for Deployment '$deployment' in namespace '$namespace' (timeout: $timeout)..."
  kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout="$timeout"
  echo "  ✅  Deployment '$deployment' is ready."
}

wait_for_pods_ready() {
  local namespace="$1"
  local selector="$2"
  local timeout="${3:-300}"
  echo "  ⏳  Waiting for pods with selector '$selector' in '$namespace'..."
  kubectl wait pod --selector="$selector" -n "$namespace" \
    --for=condition=Ready --timeout="${timeout}s"
  echo "  ✅  Pods ready."
}

# ── SCC for OpenShift (ignore errors on plain k8s) ────────────────────────────
apply_scc() {
  echo "=== [SCC] Adding anyuid SCC to service accounts (OpenShift only) ==="
  oc adm policy add-scc-to-user anyuid -z backend-sa  -n itssolutions-prod 2>/dev/null || true
  oc adm policy add-scc-to-user anyuid -z default      -n itssolutions-db   2>/dev/null || true
  oc adm policy add-scc-to-user anyuid -z vault        -n vault             2>/dev/null || true
  echo ""
}

# ── Step 1: Namespaces ─────────────────────────────────────────────────────────
echo "=== [1/7] Applying namespaces ==="
kubectl apply -f "$SCRIPT_DIR/00-namespace.yaml"
echo ""

# ── Step 2: Vault install ──────────────────────────────────────────────────────
echo "=== [2/7] Installing Vault (Helm) ==="
bash "$SCRIPT_DIR/01-vault-install.sh"
echo ""

# ── Step 3: SCC ────────────────────────────────────────────────────────────────
apply_scc

# ── Step 4: Vault configuration ───────────────────────────────────────────────
echo "=== [4/7] Configuring Vault secrets & auth ==="
bash "$SCRIPT_DIR/02-vault-config.sh"
echo ""

# ── Step 5: PostgreSQL ────────────────────────────────────────────────────────
echo "=== [5/7] Deploying PostgreSQL ==="
kubectl apply -f "$SCRIPT_DIR/03-postgres.yaml"
echo "  Waiting for PostgreSQL deployment to be ready..."
wait_for_deployment "itssolutions-db" "postgres" "300s"
wait_for_pods_ready "itssolutions-db" "app=postgres" "300"
echo ""

# ── Step 6: Backend ───────────────────────────────────────────────────────────
echo "=== [6/7] Deploying Backend (Node.js + Vault sidecar) ==="
kubectl apply -f "$SCRIPT_DIR/04-backend.yaml"
echo "  Waiting for backend deployment (includes Vault sidecar init)..."
wait_for_deployment "itssolutions-prod" "backend" "360s"
wait_for_pods_ready "itssolutions-prod" "app=backend" "360"
echo ""

# ── Step 7: Frontend + Routes ─────────────────────────────────────────────────
echo "=== [7/7] Deploying Frontend and Routes ==="
kubectl apply -f "$SCRIPT_DIR/05-frontend.yaml"
wait_for_deployment "itssolutions-prod" "frontend" "180s"

kubectl apply -f "$SCRIPT_DIR/06-routes.yaml"
echo ""

# ── Print summary ─────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                  Deployment Complete ✅                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

echo "📦  Namespaces:"
kubectl get namespaces | grep -E "itssolutions|vault" || true
echo ""

echo "🐘  PostgreSQL:"
kubectl get pods,svc -n itssolutions-db -l app=postgres || true
echo ""

echo "⚙️   Backend:"
kubectl get pods,svc -n itssolutions-prod -l app=backend || true
echo ""

echo "🌐  Frontend:"
kubectl get pods,svc -n itssolutions-prod -l app=frontend || true
echo ""

echo "🔗  Routes:"
FRONTEND_URL=""
if command -v oc &>/dev/null; then
  FRONTEND_URL=$(oc get route frontend-route -n itssolutions-prod \
    -o jsonpath='{.spec.tls.termination == "edge" && "https" || "http"}://{.spec.host}' 2>/dev/null || true)
  if [[ -z "$FRONTEND_URL" ]]; then
    FRONTEND_HOST=$(kubectl get route frontend-route -n itssolutions-prod \
      -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    [[ -n "$FRONTEND_HOST" ]] && FRONTEND_URL="https://${FRONTEND_HOST}"
  fi
fi

if [[ -n "$FRONTEND_URL" ]]; then
  echo "  ✅  Frontend URL : $FRONTEND_URL"
  echo ""
  echo "  Default credentials:"
  echo "    Username : admin"
  echo "    Password : Admin@1234!"
else
  echo "  Frontend route host not yet assigned."
  echo "  Run: kubectl get route frontend-route -n itssolutions-prod"
fi
echo ""
