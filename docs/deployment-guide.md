# Haystack RAG Application Deployment Guide

This guide provides comprehensive instructions for deploying, managing, and cleaning up the Haystack RAG (Retrieval Augmented Generation) application on Kubernetes.

## Table of Contents

- [Quick Start Guide](#quick-start-guide)
  - [Prerequisites](#prerequisites)
  - [Deployment Steps](#deployment-steps)
  - [Verification](#verification)
- [Cleanup Guide](#cleanup-guide)
  - [Resource Cleanup](#resource-cleanup)
  - [Process Cleanup](#process-cleanup)
- [Advanced Deployment Options](#advanced-deployment-options)
  - [Airgapped Deployment](#airgapped-deployment)
  - [External Secrets with Vault](#external-secrets-with-vault)
  - [Monitoring Setup](#monitoring-setup)

## Quick Start Guide

### Prerequisites

Before beginning the deployment, ensure you have the following tools installed:

- Docker (20.10+)
- Minikube (1.25+)
- kubectl (1.24+)
- Helm (3.8+)
- curl, jq, and other basic command-line utilities

System requirements:
- 2+ CPU cores
- 4+ GB of RAM
- 50+ GB of free disk space

### Deployment Steps

The Haystack RAG application can be deployed using our all-in-one script that orchestrates the complete setup process:

```bash
# Navigate to the scripts directory
cd scripts

# Run the deployment script with the "forge" command
./the-one-script.sh forge
```

This script performs the following operations in sequence:

1. Initializes a Minikube cluster with necessary addons
2. Sets up container images in Minikube
3. Configures Vault and Consul for secret management
4. Deploys the monitoring infrastructure
5. Deploys the application components

The script maintains a state file (`.deployment-state`) to track progress, allowing you to resume deployment if any step fails.

### Verification

After deployment completes, verify that all components are running:

```bash
# Check pod status
kubectl get pods

# Check service status
kubectl get services
```

Access the application at:
- http://rag.local (make sure you've updated your hosts file)
or
- http://<minikube-ip> (determined by running `minikube ip`)

Test the application API:
```bash
curl -s http://rag.local/api/health
```

## Cleanup Guide

### Resource Cleanup

To completely clean up all deployed resources:

```bash
# Navigate to the scripts directory
cd scripts

# Run the cleanup script with the "destroy-ring" command
./the-one-script.sh destroy-ring
```

This command will:
1. Prompt for confirmation before proceeding
2. Delete the Minikube cluster
3. Remove the deployment state file

### Process Cleanup

The cleanup script also identifies and displays any port-forwarding processes that might still be running:

```bash
# Find port-forward processes
ps aux | grep "[k]ubectl.*port-forward"
```

To manually kill these processes:

```bash
# Kill port-forward processes
pkill -f "kubectl.*port-forward"
```

## Advanced Deployment Options

### Airgapped Deployment

The Haystack RAG application supports deployment in airgapped environments where direct internet access is limited or unavailable.

#### Image Requirements

For airgapped deployments, all required container images must be pre-pulled and made available in a local registry. The `setup-images-for-minikube.sh` script handles this process:

```bash
# Navigate to the scripts directory
cd scripts

# Run the image setup script
./setup-images-for-minikube.sh
```

This script performs the following operations:

1. Sets up port forwarding for the Minikube registry
2. Pulls and pushes utility images (nginx, busybox)
3. Pulls and pushes the OpenSearch image
4. Builds and pushes application images (frontend, indexing, query)
5. Pulls and pushes Helm chart images (Prometheus, Grafana, Loki, Vault, Consul)
6. Tests image pulling by creating a test pod

Key code snippet from `setup-images-for-minikube.sh`:

```bash
# Function to pull, tag, and push an image
pull_tag_push() {
    local IMAGE=$1
    echo -e "${YELLOW}Processing image: ${IMAGE}${NC}"
    
    # Pull the image from its original registry
    echo -e "${GREEN}Pulling ${IMAGE}...${NC}"
    docker pull ${IMAGE}
    
    # Extract image name without registry
    local IMAGE_WITHOUT_REGISTRY=$(echo $IMAGE | awk -F/ '{print $NF}')
    
    # Tag the image for Minikube registry
    echo -e "${YELLOW}Tagging ${IMAGE} for Minikube registry...${NC}"
    docker tag ${IMAGE} ${REGISTRY_KUBE}/${IMAGE_WITHOUT_REGISTRY}
    
    # Push the image to Minikube registry
    echo -e "${GREEN}Pushing ${IMAGE} to Minikube registry...${NC}"
    docker push ${REGISTRY_KUBE}/${IMAGE_WITHOUT_REGISTRY}
}
```

#### Registry Configuration

The application is configured to use a local registry by default. This is specified in the `values.yaml` file:

```yaml
global:
  image:
    registryPath: registry.kube-system.svc.cluster.local:5000  # Local registry on Minikube
    pullPolicy: IfNotPresent
```

For airgapped deployments, ensure that:
1. All required images are available in the local registry
2. The registry is accessible from the Kubernetes cluster
3. The `registryPath` in `values.yaml` points to your local registry

### External Secrets with Vault

The application supports integration with HashiCorp Vault for enhanced secret management.

#### Vault Setup

To set up Vault for secret management:

```bash
# Navigate to the scripts directory
cd scripts

# Run the Vault setup script
./setup-vault-consul.sh
```

This script:
1. Creates namespaces for Consul and Vault
2. Installs Consul using Helm
3. Installs Vault using Helm with Consul as the storage backend
4. Initializes and unseals Vault
5. Configures Vault for Kubernetes authentication
6. Creates policies and roles for the application
7. Stores application secrets in Vault

Key code snippet from `setup-vault-consul.sh`:

```bash
# Configure Vault for Kubernetes authentication
echo -e "${YELLOW}Configuring Vault for Kubernetes authentication...${NC}"
kubectl exec vault-0 -n vault -- sh -c "
  # Login with root token
  vault login $VAULT_ROOT_TOKEN

  # Enable Kubernetes authentication
  vault auth enable kubernetes

  # Configure Kubernetes authentication
  vault write auth/kubernetes/config \\
    kubernetes_host=\"https://\$KUBERNETES_PORT_443_TCP_ADDR:443\" \\
    token_reviewer_jwt=\"\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\" \\
    kubernetes_ca_cert=\"\$(cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)\" \\
    issuer=\"https://kubernetes.default.svc.cluster.local\"

  # Enable KV secrets engine
  vault secrets enable -version=2 kv

  # Create policy for Haystack RAG application
  vault policy write haystack-rag-policy - <<'EOF'
path \"kv/data/haystack-rag/*\" {
  capabilities = [\"read\"]
}
EOF

  # Create role for Haystack RAG application
  vault write auth/kubernetes/role/haystack-rag \\
    bound_service_account_names=haystack-rag \\
    bound_service_account_namespaces=default \\
    policies=haystack-rag-policy \\
    ttl=1h
"
```

#### Vault Integration

The application is configured to use Vault for secrets in the `values.yaml` file:

```yaml
global:
  secrets:
    useExternalSecrets: true  # Set this to true to use external secrets
    name: "hra-secrets"  # E.g., from `kubectl create secret generic hra-secrets ..`
  vault:
    enabled: true  # Set to true to use Vault for secrets
    role: "haystack-rag"  # Role for Vault authentication
    serviceAccount: "haystack-rag"  # Service account for Vault authentication
    secrets:
      - name: "opensearch"
        path: "kv/data/haystack-rag/opensearch"
        template: |
          {{- with secret "kv/data/haystack-rag/opensearch" -}}
          export OPENSEARCH_USER="{{ .Data.data.adminUser }}"
          export OPENSEARCH_PASSWORD="{{ .Data.data.adminPassword }}"
          {{- end -}}
      - name: "openai"
        path: "kv/data/haystack-rag/openai"
        template: |
          {{- with secret "kv/data/haystack-rag/openai" -}}
          export OPENAI_API_KEY="{{ .Data.data.apiKey }}"
          {{- end -}}
```

To use Vault for secrets:
1. Ensure the `useExternalSecrets` and `vault.enabled` settings are set to `true`
2. Configure the Vault role and service account
3. Define the secret paths and templates

### Monitoring Setup

The application includes a comprehensive monitoring stack with Prometheus, Grafana, and Loki.

#### Monitoring Installation

To set up monitoring:

```bash
# Navigate to the scripts directory
cd scripts

# Run the monitoring setup script
./setup-monitoring.sh
```

This script:
1. Creates a namespace for monitoring
2. Adds Prometheus and Grafana Helm repositories
3. Installs kube-prometheus-stack (includes Prometheus Operator, Prometheus, AlertManager, and Grafana)
4. Installs Loki for log aggregation
5. Configures Loki as a datasource in Grafana
6. Sets up port forwarding for Grafana UI
7. Creates ServiceMonitor for the application

Key code snippet from `setup-monitoring.sh`:

```bash
# Install kube-prometheus-stack (includes Prometheus Operator, Prometheus, AlertManager, and Grafana)
echo -e "${YELLOW}Installing kube-prometheus-stack using Helm...${NC}"
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set global.imageRegistry=registry.kube-system.svc.cluster.local:5000 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=2Gi \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.size=5Gi
```

#### ServiceMonitor Configuration

The script creates a ServiceMonitor to collect metrics from the application:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: haystack-rag
  namespace: monitoring
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/instance: hra-minikube
  namespaceSelector:
    matchNames:
      - default
  endpoints:
  - port: indexing-api
    path: /metrics
    interval: 15s
  - port: query-api
    path: /metrics
    interval: 15s
```

#### Accessing Monitoring Dashboards

- **Grafana**: Access at http://localhost:3000 (default credentials: admin/admin)
- **Prometheus**: Available at http://localhost:9090 when port-forwarded

The script automatically imports a Kubernetes dashboard and provides instructions for importing additional dashboards.
