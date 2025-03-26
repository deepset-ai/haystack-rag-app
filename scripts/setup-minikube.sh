#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
CPU_COUNT=2
MEMORY_SIZE=4g
DISK_SIZE=50g
DRIVER="docker"

# Function to display usage information
function show_usage {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --registry-port PORT  Set registry port (default: 50665)"
    echo "  --cpus COUNT          Set number of CPUs (default: 2)"
    echo "  --memory SIZE         Set memory size (default: 4g)"
    echo "  --disk-size SIZE      Set disk size (default: 50g)"
    echo "  --driver DRIVER       Set driver (default: docker)"
    echo "  --help                Show this help message"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry-port)
            REGISTRY_PORT="$2"
            shift 2
            ;;
        --cpus)
            CPU_COUNT="$2"
            shift 2
            ;;
        --memory)
            MEMORY_SIZE="$2"
            shift 2
            ;;
        --disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        --driver)
            DRIVER="$2"
            shift 2
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

echo -e "${GREEN}Setting up Minikube for Haystack RAG Application...${NC}"
echo -e "${BLUE}CPU Count: ${CPU_COUNT}${NC}"
echo -e "${BLUE}Memory Size: ${MEMORY_SIZE}${NC}"
echo -e "${BLUE}Disk Size: ${DISK_SIZE}${NC}"
echo -e "${BLUE}Driver: ${DRIVER}${NC}"


# Check if minikube is installed
if ! command -v minikube &> /dev/null; then
    echo -e "${RED}Minikube is not installed. Please install it first.${NC}"
    echo "Visit https://minikube.sigs.k8s.io/docs/start/ for installation instructions."
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl is not installed. Please install it first.${NC}"
    echo "Visit https://kubernetes.io/docs/tasks/tools/install-kubectl/ for installation instructions."
    exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo -e "${RED}Helm is not installed. Please install it first.${NC}"
    echo "Visit https://helm.sh/docs/intro/install/ for installation instructions."
    exit 1
fi

# Check if docker is installed (for docker driver)
if [ "$DRIVER" = "docker" ] && ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker is not installed, but the docker driver was specified.${NC}"
    echo "Visit https://docs.docker.com/get-docker/ for installation instructions."
    exit 1
fi

# Check if minikube is already running
if minikube status &> /dev/null; then
    echo -e "${YELLOW}Minikube is already running. Stopping it to apply new configuration...${NC}"
    minikube stop
fi

# Start minikube with specified resources
echo -e "${YELLOW}Starting Minikube with ${CPU_COUNT} CPUs, ${MEMORY_SIZE} RAM, and ${DISK_SIZE} disk...${NC}"
minikube start --cpus="$CPU_COUNT" --memory="$MEMORY_SIZE" --disk-size="$DISK_SIZE" --driver="$DRIVER"

# Enable necessary addons
echo -e "${YELLOW}Enabling Ingress addon...${NC}"
minikube addons enable ingress

# Verify that NGINX Ingress Controller is properly installed
echo -e "${YELLOW}Verifying NGINX Ingress Controller installation...${NC}"
RETRY_COUNT=0
MAX_RETRIES=30
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -o name &> /dev/null; then
        echo -e "${GREEN}NGINX Ingress Controller is installed and running.${NC}"
        break
    fi
    echo -e "${YELLOW}Waiting for NGINX Ingress Controller to be ready... (Attempt $((RETRY_COUNT+1))/$MAX_RETRIES)${NC}"
    sleep 5
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}Timed out waiting for NGINX Ingress Controller to be ready.${NC}"
    echo -e "${YELLOW}You may need to verify the installation manually:${NC}"
    echo "kubectl get pods -n ingress-nginx"
fi

# Enable registry
echo -e "${YELLOW}Enabling Registry addon...${NC}"
minikube addons enable registry


# Enable Metrics Server addon
echo -e "${YELLOW}Enabling Metrics Server addon...${NC}"
minikube addons enable metrics-server

# Add rag.local to /etc/hosts
echo -e "${YELLOW}Getting Minikube IP for hosts file configuration...${NC}"
MINIKUBE_IP=$(minikube ip)
echo -e "${GREEN}Minikube IP: ${MINIKUBE_IP}${NC}"
echo -e "${YELLOW}Please add the following line to your /etc/hosts file:${NC}"
echo -e "${BLUE}${MINIKUBE_IP} rag.local${NC}"

# Add Helm repositories
echo -e "${YELLOW}Adding Helm repositories...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

echo -e "${GREEN}Minikube setup completed successfully!${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Set up registry tunnel by running: ./scripts/setup-registry-tunnel.sh"
echo "2. Build and push Docker images to the local registry"
echo "3. Deploy the Haystack RAG application using Helm"
echo "4. Access the application at http://rag.local"

# Save configuration for other scripts to use
CONFIG_DIR="$(dirname "$0")/../.config"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/minikube-config.env" << EOF
# Minikube configuration
MINIKUBE_IP=${MINIKUBE_IP}
EOF

echo -e "${GREEN}Configuration saved to ${CONFIG_DIR}/minikube-config.env${NC}"
