#!/usr/bin/env bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default values
RELEASE_NAME="hra-minikube"
NAMESPACE="default"
CHART_DIR="./charts"
REGISTRY_HOST="registry.kube-system.svc.cluster.local"
REGISTRY_PORT_INSIDE=5000
REGISTRY_KUBE="${REGISTRY_HOST}:${REGISTRY_PORT_INSIDE}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --release-name)
      RELEASE_NAME="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --chart-dir)
      CHART_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--release-name NAME] [--namespace NAMESPACE] [--chart-dir CHART_DIR]"
      exit 1
      ;;
  esac
done

echo -e "${GREEN}Deploying Haystack RAG Application with Vault Integration...${NC}"

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

# Check if Vault is running
if ! kubectl get pods -n vault -l app.kubernetes.io/name=vault -o name &> /dev/null; then
    echo -e "${RED}Vault is not running. Please run setup-vault-consul.sh first.${NC}"
    exit 1
fi

# Check if Helm release already exists
if helm list -q | grep -q "$RELEASE_NAME"; then
  echo -e "${YELLOW}Helm release '$RELEASE_NAME' already exists. Upgrading...${NC}"
  HELM_CMD="upgrade"
else
  echo -e "${YELLOW}Installing new Helm release '$RELEASE_NAME'...${NC}"
  HELM_CMD="install"
fi

# Prepare Helm command
HELM_ARGS=()
HELM_ARGS+=("$HELM_CMD" "$RELEASE_NAME" "$CHART_DIR")
HELM_ARGS+=("--namespace" "$NAMESPACE")
HELM_ARGS+=("--set" "global.vault.enabled=true")
HELM_ARGS+=("--set" "global.image.registryPath=$REGISTRY_KUBE")
HELM_ARGS+=("--set" "global.image.pullPolicy=IfNotPresent")

# Deploy Haystack RAG application using Helm
echo -e "${YELLOW}Deploying Haystack RAG application using Helm...${NC}"
helm "${HELM_ARGS[@]}"

# Wait for pods to be ready
echo -e "${YELLOW}Waiting for pods to be ready...${NC}"
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=$RELEASE_NAME --namespace $NAMESPACE --timeout=300s || true

# Get the URL for the application
echo -e "${YELLOW}Getting the URL for the application...${NC}"
MINIKUBE_IP=$(minikube ip)
echo -e "${GREEN}Haystack RAG Application deployed successfully!${NC}"
echo -e "${YELLOW}You can access the application at:${NC}"
echo "http://rag.local"
echo "or"
echo "http://$MINIKUBE_IP"

# Verify Vault integration
echo -e "${YELLOW}Verifying Vault integration...${NC}"
QUERY_POD=$(kubectl get pods -l app.kubernetes.io/component=query -n $NAMESPACE -o name | head -1)
INDEXING_POD=$(kubectl get pods -l app.kubernetes.io/component=indexing -n $NAMESPACE -o name | head -1)

if [ -n "$QUERY_POD" ]; then
    echo -e "${YELLOW}Checking Vault integration in query pod...${NC}"
    if kubectl exec $QUERY_POD -n $NAMESPACE -- ls -la /vault/secrets/ 2>/dev/null | grep -q "opensearch"; then
        echo -e "${GREEN}Vault integration is working in query pod.${NC}"
    else
        echo -e "${RED}Vault integration is not working in query pod.${NC}"
        echo -e "${YELLOW}Check the pod logs for more information:${NC}"
        echo "kubectl logs $QUERY_POD -n $NAMESPACE"
    fi
fi

if [ -n "$INDEXING_POD" ]; then
    echo -e "${YELLOW}Checking Vault integration in indexing pod...${NC}"
    if kubectl exec $INDEXING_POD -n $NAMESPACE -- ls -la /vault/secrets/ 2>/dev/null | grep -q "opensearch"; then
        echo -e "${GREEN}Vault integration is working in indexing pod.${NC}"
    else
        echo -e "${RED}Vault integration is not working in indexing pod.${NC}"
        echo -e "${YELLOW}Check the pod logs for more information:${NC}"
        echo "kubectl logs $INDEXING_POD -n $NAMESPACE"
    fi
fi

echo -e "${GREEN}Deployment completed successfully!${NC}"
echo -e "${YELLOW}If you encounter any issues, check the pod logs for more information.${NC}"
