# ITS Solutions - OpenShift Application Deployment

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [File Structure](#file-structure)
- [Namespaces](#namespaces)
- [Deployment Guide](#deployment-guide)
  - [Step 1 - Create Namespaces](#step-1---create-namespaces)
  - [Step 2 - Install Vault](#step-2---install-vault)
  - [Step 3 - Deploy PostgreSQL](#step-3---deploy-postgresql)
  - [Step 4 - Configure Vault](#step-4---configure-vault)
  - [Step 5 - Deploy Backend](#step-5---deploy-backend)
  - [Step 6 - Deploy Frontend](#step-6---deploy-frontend)
  - [Step 7 - Create Routes](#step-7---create-routes)
- [Default Credentials](#default-credentials)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)
- [Notes](#notes)

---

## Prerequisites

Before deploying, ensure the following tools are installed and configured on your workstation:

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| `oc` | 4.10+ | OpenShift CLI |
| `kubectl` | 1.24+ | Kubernetes CLI |
| `helm` | 3.10+ | Helm package manager |
| `curl` | Any | HTTP requests during Vault setup |
| `jq` | 1.6+ | JSON parsing for Vault responses |
| `bash` | 4.0+ | Shell scripts execution |

### OpenShift Cluster Requirements

- OpenShift 4.10 or higher
- Cluster-admin privileges (required for SCC, namespace creation, Helm install)
- PersistentVolume provisioner available in the cluster
- Vault Helm chart accessible (internet access or internal mirror)
- Vault Agent Injector mutating webhook enabled after install

### Verify Prerequisites

```bash
# Check oc login
oc whoami

# Verify cluster-admin
oc auth can-i create namespace --all-namespaces

# Check Helm
helm version

# Check jq
jq --version
```

### Quick Start
Clone or download this repository, then run the full automated deployment:
```bash
# Clone repository
git clone https://github.com/your-org/itssolutions-openshift.git
cd itssolutions-openshift/k8s

# Make scripts executable
chmod +x deploy.sh cleanup.sh 01-vault-install.sh 02-vault-config.sh

# Run full deployment
./deploy.sh
```
The deploy.sh script will:

1. Create all namespaces
2. Apply SCC anyuid to required ServiceAccounts
3. Install and initialize HashiCorp Vault
4. Deploy PostgreSQL and wait for readiness
5. Configure Vault secrets and policies
6. Deploy the backend and wait for readiness
7. Deploy the frontend
8. Create OpenShift Routes with TLS
9. Print the final HTTPS frontend URL

### File Structure
```bash
k8s/
├── 00-namespace.yaml        # Namespace definitions
├── 01-vault-install.sh      # Vault Helm install + init + unseal
├── 02-vault-config.sh       # Vault secrets, policies, auth config
├── 03-postgres.yaml         # PostgreSQL Deployment + PVC + Service
├── 04-backend.yaml          # Node.js backend Deployment + Service
├── 05-frontend.yaml         # Nginx frontend Deployment + Service
├── 06-routes.yaml           # OpenShift Routes (TLS edge)
├── deploy.sh                # Full automated deployment script
└── cleanup.sh               # Full teardown script
```
#### Namespaces
The deployment uses three isolated namespaces:
```bash
| Namespace | Purpose | Resources |
|-----------|---------|-----------|
| `vault` | HashiCorp Vault server + agent injector | Vault Pod, Service, ServiceAccount |
| `itssolutions-db` | PostgreSQL database | Deployment, PVC, Service, ServiceAccount |
| `itssolutions-prod` | Frontend + Backend application | Deployments, Services, Routes, ServiceAccounts |

```
