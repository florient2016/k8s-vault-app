#!/usr/bin/env bash
set -euo pipefail

echo "=== [1/4] Adding HashiCorp Helm repository ==="
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

echo "=== [2/4] Installing Vault via Helm in namespace 'vault' ==="
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set "server.dev.enabled=false" \
  --set "server.ha.enabled=false" \
  --set "injector.enabled=true" \
  --set "server.dataStorage.enabled=true" \
  --set "server.dataStorage.size=1Gi" \
  --wait --timeout 300s

echo "=== [3/4] Waiting for Vault pod to be Running ==="
kubectl wait --namespace vault \
  --for=condition=Ready pod \
  --selector app.kubernetes.io/name=vault \
  --timeout=300s

echo "=== [4/4] Initializing and unsealing Vault (single-node dev-like init) ==="
# Initialize Vault
INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json)

UNSEAL_KEY=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][0])")
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['root_token'])")

echo "Unseal Key : $UNSEAL_KEY"
echo "Root Token : $ROOT_TOKEN"

# Persist keys locally for the config script
echo "$UNSEAL_KEY" > /tmp/vault-unseal-key.txt
echo "$ROOT_TOKEN"  > /tmp/vault-root-token.txt

# Unseal
kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY"

echo ""
echo "✅  Vault installed, initialized and unsealed."
echo "    Unseal key saved to : /tmp/vault-unseal-key.txt"
echo "    Root token saved to : /tmp/vault-root-token.txt"
