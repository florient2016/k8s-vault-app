#!/usr/bin/env bash
set -euo pipefail

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         ITSSolutions – Kubernetes Cleanup Script         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "⚠️  This will DELETE the following namespaces:"
echo "    • itssolutions-prod"
echo "    • itssolutions-db"
echo ""
read -r -p "Are you sure? Type 'yes' to continue: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "=== [1/5] Deleting Routes ==="
kubectl delete route --all -n itssolutions-prod --ignore-not-found=true 2>/dev/null || true

echo "=== [2/5] Deleting namespace: itssolutions-prod ==="
kubectl delete namespace itssolutions-prod --ignore-not-found=true
echo "  Waiting for itssolutions-prod to be fully deleted..."
kubectl wait --for=delete namespace/itssolutions-prod --timeout=120s 2>/dev/null || true

echo "=== [3/5] Deleting namespace: itssolutions-db ==="
kubectl delete namespace itssolutions-db --ignore-not-found=true
echo "  Waiting for itssolutions-db to be fully deleted..."
kubectl wait --for=delete namespace/itssolutions-db --timeout=120s 2>/dev/null || true

echo "=== [4/5] (Optional) Uninstalling Vault Helm release ==="
read -r -p "Also remove Vault from namespace 'vault'? [y/N]: " REMOVE_VAULT
if [[ "$REMOVE_VAULT" =~ ^[Yy]$ ]]; then
  helm uninstall vault -n vault --ignore-not-found 2>/dev/null || true
  kubectl delete namespace vault --ignore-not-found=true
  kubectl wait --for=delete namespace/vault --timeout=120s 2>/dev/null || true
  echo "  Vault namespace deleted."
else
  echo "  Skipping Vault removal."
fi

echo ""
echo "=== [5/5] Verification ==="
echo ""
echo "Checking for remaining namespaces..."
REMAINING=""
for ns in itssolutions-prod itssolutions-db; do
  if kubectl get namespace "$ns" &>/dev/null 2>&1; then
    REMAINING="$REMAINING $ns"
    echo "  ⚠️  Namespace '$ns' still exists (may still be terminating)"
  else
    echo "  ✅  Namespace '$ns' is gone."
  fi
done

if [[ "$REMOVE_VAULT" =~ ^[Yy]$ ]]; then
  if kubectl get namespace vault &>/dev/null 2>&1; then
    echo "  ⚠️  Namespace 'vault' still exists (may still be terminating)"
  else
    echo "  ✅  Namespace 'vault' is gone."
  fi
fi

echo ""
if [[ -z "$REMAINING" ]]; then
  echo "✅  All ITSSolutions resources have been successfully removed."
else
  echo "⚠️  Some namespaces are still terminating. Run:"
  echo "    kubectl get namespaces | grep itssolutions"
fi
echo ""

# Clean up local Vault key files
rm -f /tmp/vault-unseal-key.txt /tmp/vault-root-token.txt 2>/dev/null || true
echo "   Local Vault key files removed."
echo ""
echo "Done."
