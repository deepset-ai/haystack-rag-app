#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}Setting up HashiCorp Vault with Consul backend for Haystack RAG Application...${NC}"

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl is not installed. Please install it first.${NC}"
    exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo -e "${RED}Helm is not installed. Please install it first.${NC}"
    exit 1
fi

# Check if minikube is running
if ! minikube status | grep -q "Running"; then
    echo -e "${RED}Minikube is not running. Please start it first.${NC}"
    exit 1
fi

# Check if jq is installed (needed for JSON parsing)
if ! command -v jq &> /dev/null; then
    echo -e "${RED}jq is not installed. Please install it first.${NC}"
    exit 1
fi

# Prompt for secret values
echo -e "${YELLOW}Please enter the following secret values:${NC}"
read -p "OpenSearch Admin User [admin]: " OPENSEARCH_USER
OPENSEARCH_USER=${OPENSEARCH_USER:-admin}

read -p "OpenSearch Admin Password: " -s OPENSEARCH_PASSWORD
echo
if [ -z "$OPENSEARCH_PASSWORD" ]; then
    echo -e "${RED}OpenSearch Admin Password cannot be empty.${NC}"
    exit 1
fi

read -p "OpenAI API Key: " -s OPENAI_API_KEY
echo
if [ -z "$OPENAI_API_KEY" ]; then
    echo -e "${RED}OpenAI API Key cannot be empty.${NC}"
    exit 1
fi

# Get registry path from values.yaml
REGISTRY_PATH=$(grep -A1 "registryPath:" charts/values.yaml | tail -1 | awk '{print $2}')
echo -e "${YELLOW}Using registry path: ${REGISTRY_PATH}${NC}"

# Create namespace for Consul and Vault
echo -e "${YELLOW}Creating namespaces for Consul and Vault...${NC}"
kubectl create namespace consul --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

# Add HashiCorp Helm repository
echo -e "${YELLOW}Adding HashiCorp Helm repository...${NC}"
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Install Consul using Helm
echo -e "${YELLOW}Installing Consul using Helm...${NC}"
helm install consul hashicorp/consul \
  --namespace consul \
  --set "global.name=consul" \
  --set "global.datacenter=development" \
  --set "global.imageRegistry=${REGISTRY_PATH}" \
  --set "server.replicas=1" \
  --set "server.bootstrapExpect=1" \
  --set "server.disruptionBudget.enabled=true" \
  --set "server.disruptionBudget.maxUnavailable=0" \
  --set "server.resources.requests.memory=256Mi" \
  --set "server.resources.requests.cpu=250m" \
  --set "server.resources.limits.memory=512Mi" \
  --set "server.resources.limits.cpu=500m" \
  --set "client.enabled=true" \
  --set "ui.enabled=true" \
  --set "ui.service.type=ClusterIP"

# Wait for Consul to be ready
echo -e "${YELLOW}Waiting for Consul to be ready...${NC}"
kubectl wait --for=condition=Ready pod -l app=consul,component=server --namespace consul --timeout=300s

# Install Vault using Helm with Consul as the storage backend
echo -e "${YELLOW}Installing Vault using Helm with Consul as the storage backend...${NC}"
helm install vault hashicorp/vault \
  --namespace vault \
  --set "server.ha.enabled=true" \
  --set "server.ha.replicas=3" \
  --set "server.service.enabled=true" \
  --set "server.dataStorage.enabled=true" \
  --set "server.dataStorage.size=10Gi" \
  --set "server.dataStorage.storageClass=standard" \
  --set "server.dataStorage.accessMode=ReadWriteOnce" \
  --set "server.auditStorage.enabled=true" \
  --set "server.auditStorage.size=10Gi" \
  --set "server.auditStorage.storageClass=standard" \
  --set "server.auditStorage.accessMode=ReadWriteOnce" \
  --set "server.standalone.enabled=false" \
  --set "server.serviceAccount.create=true" \
  --set "server.serviceAccount.name=vault" \
  --set "injector.enabled=true" \
  --set "injector.resources.requests.memory=256Mi" \
  --set "injector.resources.requests.cpu=250m" \
  --set "injector.resources.limits.memory=512Mi" \
  --set "injector.resources.limits.cpu=500m" \
  --set "injector.webhook.failurePolicy=Ignore" \
  --set "injector.webhook.timeoutSeconds=30" \
  --set-string "server.config.storage.consul.address=consul-server.consul.svc:8500" \
  --set-string "server.config.storage.consul.path=vault/" \
  --set-string "server.config.storage.consul.service=vault" \
  --set-string "server.config.listener.tcp.address=[::]:8200" \
  --set-string "server.config.listener.tcp.tls_disable=true" \
  --set-string "server.config.ui=true"

# Wait for Vault pods to be created
echo -e "${YELLOW}Waiting for Vault pods to be created...${NC}"
sleep 30

# Wait for Vault pods to be ready
echo -e "${YELLOW}Waiting for Vault pods to be ready...${NC}"
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault --namespace vault --timeout=300s

# Initialize Vault
echo -e "${YELLOW}Initializing Vault...${NC}"
# Check if cluster-keys.json already exists
if [ -f "cluster-keys.json" ]; then
    echo -e "${YELLOW}cluster-keys.json already exists. Using existing keys.${NC}"
else
    echo -e "${YELLOW}Initializing Vault and saving keys to cluster-keys.json...${NC}"
    kubectl exec vault-0 -n vault -- vault operator init -key-shares=5 -key-threshold=3 -format=json > cluster-keys.json
fi

# Extract unseal keys and root token
VAULT_UNSEAL_KEY1=$(cat cluster-keys.json | jq -r ".unseal_keys_b64[0]")
VAULT_UNSEAL_KEY2=$(cat cluster-keys.json | jq -r ".unseal_keys_b64[1]")
VAULT_UNSEAL_KEY3=$(cat cluster-keys.json | jq -r ".unseal_keys_b64[2]")
VAULT_ROOT_TOKEN=$(cat cluster-keys.json | jq -r ".root_token")

# Unseal Vault pods
echo -e "${YELLOW}Unsealing Vault pods...${NC}"
for i in {0..2}; do
    echo -e "${YELLOW}Unsealing vault-$i...${NC}"
    kubectl exec vault-$i -n vault -- vault operator unseal $VAULT_UNSEAL_KEY1
    kubectl exec vault-$i -n vault -- vault operator unseal $VAULT_UNSEAL_KEY2
    kubectl exec vault-$i -n vault -- vault operator unseal $VAULT_UNSEAL_KEY3
done

# Set up port forwarding for Vault UI in detached mode
echo -e "${YELLOW}Setting up port forwarding for Vault UI...${NC}"
# Start port forwarding in background
nohup kubectl port-forward --namespace vault service/vault-ui 8200:8200 > /tmp/vault-port-forward.log 2>&1 &
PORT_FORWARD_PID=$!
echo -e "${GREEN}Vault UI port forwarding started with PID ${PORT_FORWARD_PID}.${NC}"

# Wait for Vault UI to be accessible
echo -e "${YELLOW}Waiting for Vault UI to be accessible...${NC}"
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s http://localhost:8200/ui/ > /dev/null; then
        echo -e "${GREEN}Vault UI is accessible at http://localhost:8200/ui/${NC}"
        break
    fi
    echo -e "${YELLOW}Waiting for Vault UI to be accessible... (Attempt $((RETRY_COUNT+1))/$MAX_RETRIES)${NC}"
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}Timed out waiting for Vault UI to be accessible.${NC}"
    echo -e "${YELLOW}Check the port forwarding log:${NC}"
    echo "cat /tmp/vault-port-forward.log"
    exit 1
fi

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

  # Create secrets for Haystack RAG application with user-provided values
  vault kv put kv/haystack-rag/opensearch \\
    adminUser=\"$OPENSEARCH_USER\" \\
    adminPassword=\"$OPENSEARCH_PASSWORD\"

  vault kv put kv/haystack-rag/openai \\
    apiKey=\"$OPENAI_API_KEY\"
"

# Create service account for Haystack RAG application
echo -e "${YELLOW}Creating service account for Haystack RAG application...${NC}"
kubectl create serviceaccount haystack-rag --namespace default --dry-run=client -o yaml | kubectl apply -f -

# Update global.vault.enabled in values.yaml
echo -e "${YELLOW}Updating global.vault.enabled in values.yaml...${NC}"
sed -i 's/enabled: false  # Set to true to use Vault for secrets/enabled: true  # Set to true to use Vault for secrets/g' charts/values.yaml

# Display admin credentials and next steps
echo -e "${GREEN}HashiCorp Vault with Consul backend setup completed successfully!${NC}"
echo -e "${BLUE}Vault UI is accessible at: http://localhost:8200${NC}"
echo -e "${YELLOW}Root Token: ${VAULT_ROOT_TOKEN}${NC}"

echo -e "${GREEN}Integration with Haystack RAG application:${NC}"
echo -e "${YELLOW}The values.yaml file has been updated to use Vault for secrets.${NC}"

echo -e "${YELLOW}Next steps:${NC}"
echo "1. Deploy the Haystack RAG application using Helm with Vault integration"
echo "2. Verify that the application can access the secrets from Vault"

# Instructions for adding annotations to application pods
echo -e "${YELLOW}To inject secrets into your application pods, add the following annotations to your deployment templates:${NC}"
echo "annotations:"
echo "  vault.hashicorp.com/agent-inject: \"true\""
echo "  vault.hashicorp.com/agent-inject-secret-config: \"kv/data/haystack-rag/config\""
echo "  vault.hashicorp.com/role: \"haystack-rag\""
echo "  vault.hashicorp.com/agent-inject-template-config: |"
echo "    {{- with secret \"kv/data/haystack-rag/config\" -}}"
echo "    export OPENSEARCH_USER=\"{{ .Data.data.adminUser }}\""
echo "    export OPENSEARCH_PASSWORD=\"{{ .Data.data.adminPassword }}\""
echo "    export OPENAI_API_KEY=\"{{ .Data.data.apiKey }}\""
echo "    {{- end -}}"
