#!/usr/bin/env bash
set -euo pipefail

echo "=============================================="
echo " ITS Solutions - Cleanup Script"
echo "=============================================="
echo ""
echo "WARNING: This will delete the following namespaces:"
echo "  - itssolutions-prod"
echo "  - itssolutions-db"
echo "  - vault"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Cleanup cancelled."
  exit 0
fi

echo ""
echo "=== Removing SCC policies (ignore errors if already removed) ==="
oc adm policy remove-scc-from-user anyuid -z postgres-sa -n itssolutions-db 2>/dev/null || true
oc adm policy remove-scc-from-user anyuid -z backend-sa -n itssolutions-prod 2>/dev/null || true
oc adm policy remove-scc-from-user anyuid -z frontend-sa -n itssolutions-prod 2>/dev/null || true

echo ""
echo "=== Uninstalling Vault Helm release ==="
helm uninstall vault --namespace vault 2>/dev/null || echo "Vault Helm release not found (skipping)."

echo ""
echo "=== Deleting namespace: itssolutions-prod ==="
oc delete namespace itssolutions-prod --ignore-not-found=true
echo "Namespace itssolutions-prod deletion initiated."

echo ""
echo "=== Deleting namespace: itssolutions-db ==="
oc delete namespace itssolutions-db --ignore-not-found=true
echo "Namespace itssolutions-db deletion initiated."

echo ""
echo "=== Deleting namespace: vault ==="
oc delete namespace vault --ignore-not-found=true
echo "Namespace vault deletion initiated."

echo ""
echo "=== Waiting for namespaces to be fully deleted ==="
echo "This may take a few minutes..."

wait_for_namespace_deletion() {
  local NS="$1"
  local RETRIES=0
  while oc get namespace "$NS" >/dev/null 2>&1; do
    RETRIES=$((RETRIES+1))
    if [ $RETRIES -gt 60 ]; then
      echo "WARNING: Namespace $NS still exists after 5 minutes. It may have stuck finalizers."
      break
    fi
    echo "  Waiting for namespace $NS to be deleted... ($RETRIES/60)"
    sleep 5
  done
  if ! oc get namespace "$NS" >/dev/null 2>&1; then
    echo "  ✓ Namespace $NS deleted."
  fi
}

wait_for_namespace_deletion "itssolutions-prod"
wait_for_namespace_deletion "itssolutions-db"
wait_for_namespace_deletion "vault"

echo ""
echo "=== Verifying cleanup ==="
ALL_CLEAN=true

for NS in itssolutions-prod itssolutions-db vault; do
  if oc get namespace "$NS" >/dev/null 2>&1; then
    echo "  ✗ Namespace $NS still exists (may have stuck finalizers - check with: oc get namespace $NS -o yaml)"
    ALL_CLEAN=false
  else
    echo "  ✓ Namespace $NS: GONE"
  fi
done

echo ""
if [ "$ALL_CLEAN" = true ]; then
  echo "=============================================="
  echo " Cleanup SUCCESSFUL - All resources removed."
  echo "=============================================="
else
  echo "=============================================="
  echo " Cleanup PARTIAL - Some namespaces still exist."
  echo " To force-remove stuck namespaces, run:"
  echo "   oc get namespace <name> -o json | python3 -c \"
  echo "   'import sys,json; d=json.load(sys.stdin); d["spec"]["finalizers"]=[]; print(json.dumps(d))' | \"
  echo "   oc replace --raw /api/v1/namespaces/<name>/finalize -f -"
  echo "=============================================="
fi

# Clean up local vault-keys.txt if present
if [ -f vault-keys.txt ]; then
  read -p "Delete local vault-keys.txt? (yes/no): " DEL_KEYS
  if [ "$DEL_KEYS" = "yes" ]; then
    rm -f vault-keys.txt
    echo "vault-keys.txt deleted."
  fi
fi

echo ""
echo "Cleanup complete."
