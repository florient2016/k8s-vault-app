# k8s-vault-app

A Kubernetes-based application deployment solution with HashiCorp Vault integration for secrets management.

## Overview

This project demonstrates a complete deployment pipeline for a multi-tier application on Kubernetes/OpenShift, featuring:
- PostgreSQL database
- Node.js/Express backend
- Frontend service
- HashiCorp Vault for secrets management
- Vault Agent injection for pod-level secrets

## Architecture

```
┌─────────────────────────────────────────────┐
│         OpenShift Cluster                   │
├─────────────────────────────────────────────┤
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │  itssolutions-prod (Namespace)       │  │
│  │  ├─ Frontend (Pod)                   │  │
│  │  ├─ Backend (Pod)                    │  │
│  │  └─ Vault Agent Injector             │  │
│  └──────────────────────────────────────┘  │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │  itssolutions-db (Namespace)         │  │
│  │  └─ PostgreSQL (Pod)                 │  │
│  └──────────────────────────────────────┘  │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │  vault-system (Namespace)            │  │
│  │  └─ Vault Server                     │  │
│  └──────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

## Prerequisites

- Kubernetes 1.20+ or OpenShift 4.x
- kubectl CLI configured
- Docker installed (for building images)
- Helm 3.x (for Vault deployment)
- HashiCorp Vault 1.15+

## Quick Start

### 1. Deploy

```bash
./deploy.sh
```

This script will:
- Create namespaces (itssolutions-prod, itssolutions-db)
- Label namespaces for Vault injection
- Deploy PostgreSQL database
- Configure Vault with database secrets
- Build and push Docker images
- Deploy backend and frontend applications
- Create OpenShift routes

### 2. Access the Application

Once deployment completes:

```
✅ Application available at: https://<FRONTEND_URL>
   Default credentials: admin / Admin@1234!
```

### 3. Cleanup

To remove all resources:

```bash
./cleanup.sh
```

## Configuration

### Environment Variables

In `deploy.sh`:

```bash
REGISTRY="image-registry.openshift-image-registry.svc:5000"
NAMESPACE="itssolutions-prod"
DB_NAMESPACE="itssolutions-db"
VAULT_ADDR="http://vault.vault-system.svc.cluster.local:8200"
```

### Kubernetes Manifests

```
k8s/
├── 00-namespace.yaml          # Namespace definitions
├── 01-vault-config.yaml       # Vault configuration
├── 02-postgres.yaml           # PostgreSQL StatefulSet
├── 03-backend.yaml            # Backend Deployment
├── 04-frontend.yaml           # Frontend Deployment
└── 05-routes.yaml             # OpenShift Routes
```

## Vault Integration

The application uses Vault for:
- Database credentials management
- Pod-level secrets injection via Vault Agent
- Automatic secret rotation

### Vault Agent Configuration

Pods are annotated with:
```yaml
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/agent-inject-secret-db: "secret/data/postgres"
vault.hashicorp.com/role: "backend"
```

## Deployment Flow

1. **Namespace Creation** - Creates isolated namespaces
2. **Label Namespaces** - Enables Vault injection for pods
3. **Database Setup** - Deploys PostgreSQL
4. **Vault Configuration** - Initializes Vault with database credentials
5. **Image Build** - Builds and pushes Docker images to registry
6. **Application Deployment** - Deploys backend and frontend
7. **Route Creation** - Exposes services via OpenShift routes

## Cleanup Process

The cleanup script removes:
- Application namespaces
- Vault Helm release
- Cluster-level RBAC bindings
- Vault Agent Injector configuration
- Mutating webhook configurations

## Troubleshooting

### Pod fails to start with Vault injection error
```bash
kubectl logs -n itssolutions-prod <pod-name> -c vault-agent
```

### Database connection issues
```bash
kubectl exec -n itssolutions-db postgres-0 -- psql -U postgres -c "\l"
```

### Vault not accessible
```bash
kubectl run vault-debug --rm -it --image=alpine:latest -n itssolutions-prod -- sh
```

### Image registry authentication
Ensure ImagePullSecrets are configured in namespace for private registries.

## Security Considerations

- Vault Root Token should be stored securely (not in scripts)
- Use OpenShift service accounts for Vault authentication
- Implement network policies to restrict pod communication
- Enable SSL/TLS for Vault communication in production
- Rotate database credentials regularly

## Monitoring

Check deployment status:

```bash
# Pods
kubectl get pods -n itssolutions-prod
kubectl get pods -n itssolutions-db

# Services
kubectl get svc -n itssolutions-prod

# Routes
kubectl get routes -n itssolutions-prod

# Vault status
kubectl exec -n vault-system vault-0 -- vault status
```

## Support

For issues or questions, refer to:
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [HashiCorp Vault Documentation](https://www.vaultproject.io/docs)
- [OpenShift Documentation](https://docs.openshift.com/)
