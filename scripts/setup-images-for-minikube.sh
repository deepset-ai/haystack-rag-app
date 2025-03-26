#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Registry configuration
REGISTRY_PORT=5000
REGISTRY_HOST="registry.kube-system.svc.cluster.local"
REGISTRY_KUBE="${REGISTRY_HOST}:${REGISTRY_PORT}"

# Parse command line arguments
SKIP_HELM_IMAGES=false
SKIP_OPENSEARCH=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-helm-images)
      SKIP_HELM_IMAGES=true
      shift
      ;;
    --skip-opensearch)
      SKIP_OPENSEARCH=false
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--skip-helm-images] [--skip-opensearch]"
      exit 1
      ;;
  esac
done

echo -e "${GREEN}Setting up images for Minikube deployment in air-gapped environment...${NC}"

# Step 1: Check /etc/hosts for registry host entry
echo -e "${YELLOW}Checking /etc/hosts for registry host entry...${NC}"
if grep -q "${REGISTRY_HOST}" /etc/hosts; then
    echo -e "${GREEN}Registry host entry found in /etc/hosts.${NC}"
else
    echo -e "${RED}Registry host entry not found in /etc/hosts.${NC}"
    echo -e "${YELLOW}Please add the following entry to your /etc/hosts file:${NC}"
    echo -e "${YELLOW}127.0.0.1 ${REGISTRY_HOST}${NC}"
    echo -e "${YELLOW}Command (requires admin/sudo privileges):${NC}"
    echo -e "${YELLOW}echo \"127.0.0.1 ${REGISTRY_HOST}\" | sudo tee -a /etc/hosts${NC}"
    
    # Ask user if they want to continue anyway
    read -p "Continue anyway? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Exiting.${NC}"
        exit 1
    fi
fi

# Step 2: Check if registry service is running in Minikube
echo -e "${YELLOW}Checking if registry service is running in Minikube...${NC}"
if kubectl get service -n kube-system registry &>/dev/null; then
    echo -e "${GREEN}Registry service is running in Minikube.${NC}"
else
    echo -e "${RED}Registry service not found in Minikube.${NC}"
    echo -e "${YELLOW}Enabling registry addon in Minikube...${NC}"
    minikube addons enable registry
    echo -e "${GREEN}Registry addon enabled in Minikube.${NC}"
fi

# Step 3: Set up port forwarding for registry in detached mode
echo -e "${YELLOW}Setting up port forwarding for registry...${NC}"
# Kill any existing port forwarding processes
pkill -f "kubectl port-forward.*${REGISTRY_PORT}" || true
# Start port forwarding in background
nohup kubectl port-forward --namespace kube-system service/registry ${REGISTRY_PORT}:80 > /tmp/registry-port-forward.log 2>&1 &
PORT_FORWARD_PID=$!
echo -e "${GREEN}Port forwarding started with PID ${PORT_FORWARD_PID}.${NC}"

# Step 4: Set up socat for Docker to access the registry
echo -e "${YELLOW}Setting up socat for Docker to access the registry...${NC}"
# Kill any existing socat processes
pkill -f "socat.*${REGISTRY_PORT}" || true
# Start socat in background
nohup docker run --rm --network=host alpine ash -c "apk add socat && socat TCP-LISTEN:${REGISTRY_PORT},reuseaddr,fork TCP:host.docker.internal:${REGISTRY_PORT}" > /tmp/registry-socat.log 2>&1 &
SOCAT_PID=$!
echo -e "${GREEN}Socat started with PID ${SOCAT_PID}.${NC}"

# Wait for registry to be accessible
echo -e "${YELLOW}Waiting for registry to be accessible...${NC}"
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s http://localhost:${REGISTRY_PORT}/v2/ > /dev/null; then
        echo -e "${GREEN}Registry is accessible at http://localhost:${REGISTRY_PORT}/v2/${NC}"
        break
    fi
    echo -e "${YELLOW}Waiting for registry to be accessible... (Attempt $((RETRY_COUNT+1))/$MAX_RETRIES)${NC}"
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}Timed out waiting for registry to be accessible.${NC}"
    echo -e "${YELLOW}Check the port forwarding and socat logs:${NC}"
    echo "cat /tmp/registry-port-forward.log"
    echo "cat /tmp/registry-socat.log"
    exit 1
fi

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

# Step 5: Pull and push utility images
echo -e "${YELLOW}Pulling and pushing utility images...${NC}"

# Array of utility images
UTILITY_IMAGES=(
    "nginx:alpine"
    "busybox:latest"
)

# Process utility images
for IMAGE in "${UTILITY_IMAGES[@]}"; do
    pull_tag_push ${IMAGE}
done

# Step 6: Pull and push OpenSearch image if not skipped
if [ "$SKIP_OPENSEARCH" = false ]; then
    echo -e "${YELLOW}Pulling and pushing OpenSearch image...${NC}"
    pull_tag_push "opensearchproject/opensearch:2.18.0"
fi

# Step 7: Build and push application images
echo -e "${YELLOW}Building and pushing application images...${NC}"

# Build and push frontend image
echo -e "${YELLOW}Building frontend image...${NC}"
docker build -t ${REGISTRY_KUBE}/hra-frontend:latest -f frontend/Dockerfile.frontend frontend/
echo -e "${GREEN}Pushing frontend image to Minikube registry...${NC}"
docker push ${REGISTRY_KUBE}/hra-frontend:latest

# Build and push indexing service image
echo -e "${YELLOW}Building indexing service image...${NC}"
docker build -t ${REGISTRY_KUBE}/hra-indexing:latest -f backend/Dockerfile.indexing backend/
echo -e "${GREEN}Pushing indexing service image to Minikube registry...${NC}"
docker push ${REGISTRY_KUBE}/hra-indexing:latest

# Build and push query service image
echo -e "${YELLOW}Building query service image...${NC}"
docker build -t ${REGISTRY_KUBE}/hra-query:latest -f backend/Dockerfile.query backend/
echo -e "${GREEN}Pushing query service image to Minikube registry...${NC}"
docker push ${REGISTRY_KUBE}/hra-query:latest

# Step 8: Pull and push Helm chart images if not skipped
if [ "$SKIP_HELM_IMAGES" = false ]; then
    echo -e "${YELLOW}Pulling and pushing images used by Helm charts...${NC}"
    
    # Prometheus images
    echo -e "${BLUE}Processing Prometheus images...${NC}"
    PROMETHEUS_IMAGES=(
        "quay.io/prometheus/prometheus:v2.45.0"
        "quay.io/prometheus-operator/prometheus-operator:v0.68.0"
        "quay.io/prometheus/alertmanager:v0.26.0"
        "quay.io/prometheus/node-exporter:v1.6.1"
        "quay.io/prometheus-operator/prometheus-config-reloader:v0.68.0"
        "kiwigrid/k8s-sidecar:1.24.6"
    )
    
    for IMAGE in "${PROMETHEUS_IMAGES[@]}"; do
        pull_tag_push ${IMAGE}
    done
    
    # Grafana images
    echo -e "${BLUE}Processing Grafana images...${NC}"
    GRAFANA_IMAGES=(
        "grafana/grafana:10.1.4"
    )
    
    for IMAGE in "${GRAFANA_IMAGES[@]}"; do
        pull_tag_push ${IMAGE}
    done
    
    # Loki images
    echo -e "${BLUE}Processing Loki images...${NC}"
    LOKI_IMAGES=(
        "grafana/loki:2.9.2"
        "grafana/promtail:2.9.2"
    )
    
    for IMAGE in "${LOKI_IMAGES[@]}"; do
        pull_tag_push ${IMAGE}
    done
    
    # Vault and Consul images
    echo -e "${BLUE}Processing Vault and Consul images...${NC}"
    VAULT_CONSUL_IMAGES=(
        "hashicorp/vault:1.15.2"
        "hashicorp/vault-k8s:1.2.1"  # This is the Vault Agent Injector image
        "hashicorp/consul:1.16.1"
        "hashicorp/consul-k8s-control-plane:1.2.1"
    )
    
    for IMAGE in "${VAULT_CONSUL_IMAGES[@]}"; do
        pull_tag_push ${IMAGE}
    done
    
    echo -e "${GREEN}Helm chart images pulled and pushed successfully.${NC}"
fi

# Step 9: Test image pulling by creating a test pod
echo -e "${YELLOW}Testing image pulling by creating a test pod...${NC}"

# Delete existing test pod if it exists
kubectl delete pod nginx-test --ignore-not-found

# Create a test pod using the nginx image from the registry
kubectl run nginx-test --image=${REGISTRY_KUBE}/nginx:alpine

# Watch the pod until it's running
echo -e "${YELLOW}Watching pod until it's running...${NC}"
kubectl wait --for=condition=Ready pod/nginx-test --timeout=60s

# Get pod status
POD_STATUS=$(kubectl get pod nginx-test -o jsonpath='{.status.phase}')
if [ "$POD_STATUS" == "Running" ]; then
    echo -e "${GREEN}Test pod is running successfully!${NC}"
    kubectl get pod nginx-test
else
    echo -e "${RED}Test pod is not running. Status: ${POD_STATUS}${NC}"
    kubectl describe pod nginx-test
    exit 1
fi

echo -e "${GREEN}All images have been successfully built, pushed, and tested!${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Deploy the Haystack RAG application using Helm"
echo "2. Access the application at http://rag.local"

# Cleanup instructions
echo -e "${YELLOW}To clean up the port forwarding and socat processes:${NC}"
echo "kill $PORT_FORWARD_PID"
echo "kill $SOCAT_PID"

# Notes about Helm chart images
echo -e "${BLUE}Notes about Helm chart images:${NC}"
echo "1. All images required for Prometheus, Grafana, Loki, and Vault have been pushed to the Minikube registry."
echo "2. When deploying with Helm, you may need to update the Helm chart values to use the Minikube registry."
echo "3. For example, add the following to your Helm values:"
echo "   global:"
echo "     imageRegistry: ${REGISTRY_KUBE}"
echo "   or use the --set-string option:"
echo "   helm install prometheus prometheus-community/kube-prometheus-stack \\"
echo "     --set-string global.imageRegistry=${REGISTRY_KUBE} \\"
echo "     ..."
