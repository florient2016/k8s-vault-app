#!/usr/bin/env bash
set -euo pipefail

echo "=== [01] Installing HashiCorp Vault via Helm ==="

# Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Install Vault with injector enabled in namespace vault
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set "server.dev.enabled=false" \
  --set "server.standalone.enabled=true" \
  --set "server.standalone.config=\
ui = true\n\
listener \"tcp\" {\n\
  tls_disable = 1\n\
  address = \"[::]:8200\"\n\
  cluster_address = \"[::]:8201\"\n\
}\n\
storage \"file\" {\n\
  path = \"/vault/data\"\n\
}\n" \
  --set "injector.enabled=true" \
  --set "injector.authPath=auth/kubernetes" \
  --set "server.image.repository=hashicorp/vault" \
  --set "server.image.tag=1.15.2" \
  --set "server.resources.requests.memory=256Mi" \
  --set "server.resources.requests.cpu=250m" \
  --set "server.resources.limits.memory=512Mi" \
  --set "server.resources.limits.cpu=500m" \
  --wait --timeout=10m

echo "=== Waiting for Vault pod to be Running ==="
oc -n vault wait --for=condition=Ready pod -l app.kubernetes.io/name=vault --timeout=300s

echo "=== Initializing Vault ==="
# Initialize Vault (single key share for demo/dev simplicity)
INIT_OUTPUT=$(oc -n vault exec vault-0 -- vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json)

UNSEAL_KEY=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][0])")
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['root_token'])")

echo "=== Saving Vault keys to vault-keys.txt (KEEP SECURE) ==="
cat <<EOF > vault-keys.txt
VAULT_UNSEAL_KEY=${UNSEAL_KEY}
VAULT_ROOT_TOKEN=${ROOT_TOKEN}
EOF
chmod 600 vault-keys.txt

echo "=== Unsealing Vault ==="
oc -n vault exec vault-0 -- vault operator unseal "$UNSEAL_KEY"

echo "=== Vault installed and unsealed successfully ==="
echo "Root token and unseal key saved to vault-keys.txt"
