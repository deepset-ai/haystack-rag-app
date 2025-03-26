#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Setting up Monitoring for Haystack RAG Application...${NC}"

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

# Create namespace for monitoring
echo -e "${YELLOW}Creating namespace for monitoring...${NC}"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Add Prometheus and Grafana Helm repositories
echo -e "${YELLOW}Adding Prometheus and Grafana Helm repositories...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Install kube-prometheus-stack (includes Prometheus Operator, Prometheus, AlertManager, and Grafana)
echo -e "${YELLOW}Installing kube-prometheus-stack using Helm...${NC}"
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set global.imageRegistry=registry.kube-system.svc.cluster.local:5000 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=2Gi \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.size=5Gi

# Install Loki using Helm
echo -e "${YELLOW}Installing Loki using Helm...${NC}"
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set global.imageRegistry=registry.kube-system.svc.cluster.local:5000 \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set loki.persistence.enabled=true \
  --set loki.persistence.size=10Gi

# Configure Loki as a datasource in Grafana
echo -e "${YELLOW}Configuring Loki as a datasource in Grafana...${NC}"
kubectl create configmap loki-datasource --namespace monitoring --from-literal=loki-datasource.yaml="
apiVersion: 1
datasources:
- name: Loki
  type: loki
  url: http://loki.monitoring.svc.cluster.local:3100
  access: proxy
" --dry-run=client -o yaml | kubectl apply -f -

# Wait for Grafana pod to be ready
echo -e "${YELLOW}Waiting for Grafana pod to be ready...${NC}"
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana --namespace monitoring --timeout=300s

# Get Grafana admin password
echo -e "${YELLOW}Getting Grafana admin password...${NC}"
GRAFANA_PASSWORD=$(kubectl get secret --namespace monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
echo "Grafana admin password: $GRAFANA_PASSWORD"

# Check if port 3000 is already in use and kill the process if needed
echo -e "${YELLOW}Checking if port 3000 is already in use...${NC}"
if netstat -ano | grep -q ":3000"; then
    echo -e "${YELLOW}Port 3000 is already in use. Attempting to free it...${NC}"
    # For Windows
    if [[ "$(uname)" == "MINGW"* ]] || [[ "$(uname)" == "MSYS"* ]] || [[ "$(uname)" == "CYGWIN"* ]]; then
        # Find PID using port 3000 on Windows
        PID=$(netstat -ano | grep ":3000" | awk '{print $5}' | head -1)
        if [ ! -z "$PID" ]; then
            echo -e "${YELLOW}Killing process with PID $PID...${NC}"
            taskkill //F //PID $PID
        fi
    else
        # For Linux/Mac
        pkill -f "kubectl port-forward.*3000" || echo "No port-forwarding processes found."
    fi
fi

# Port forward Grafana UI
echo -e "${YELLOW}Setting up port forwarding for Grafana UI...${NC}"
kubectl port-forward service/prometheus-grafana --namespace monitoring 3000:80 &
echo "Grafana UI port forwarding started in the background."
echo "You can access the Grafana UI at http://localhost:3000"
echo "Username: admin"
echo "Password: $GRAFANA_PASSWORD"

# Create ServiceMonitor for Haystack RAG application if the CRD exists
echo -e "${YELLOW}Checking if ServiceMonitor CRD exists...${NC}"
# Wait for the ServiceMonitor CRD to be created
RETRY_COUNT=0
MAX_RETRIES=30
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
        echo -e "${GREEN}ServiceMonitor CRD found.${NC}"
        break
    fi
    echo -e "${YELLOW}Waiting for ServiceMonitor CRD to be created... (Attempt $((RETRY_COUNT+1))/$MAX_RETRIES)${NC}"
    sleep 5
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}Timed out waiting for ServiceMonitor CRD to be created.${NC}"
    echo -e "${YELLOW}Skipping ServiceMonitor creation. You may need to create it manually later.${NC}"
else
    echo -e "${YELLOW}Creating ServiceMonitor for Haystack RAG application...${NC}"
    cat <<EOF | kubectl apply -f -
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
EOF
fi

# Import Grafana dashboards
echo -e "${YELLOW}Importing Grafana dashboards...${NC}"

# Create temporary directory for dashboard files
TEMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'dashboards')

# Download Kubernetes dashboard
echo -e "${YELLOW}Downloading Kubernetes dashboard...${NC}"
curl -s https://grafana.com/api/dashboards/10856/revisions/1/download -o "$TEMP_DIR/kubernetes-dashboard.json"

# Create ConfigMap from downloaded file
echo -e "${YELLOW}Creating ConfigMap from downloaded dashboard...${NC}"
kubectl create configmap kubernetes-dashboard --namespace monitoring --from-file=kubernetes-dashboard.json="$TEMP_DIR/kubernetes-dashboard.json" --dry-run=client -o yaml | kubectl apply -f -

# Note about Node Exporter dashboard
echo -e "${YELLOW}Note: Node Exporter dashboard is not imported automatically as it exceeds ConfigMap size limits.${NC}"
echo -e "${YELLOW}You can import it manually through the Grafana UI if needed.${NC}"

# Clean up temporary files
echo -e "${YELLOW}Cleaning up temporary files...${NC}"
rm -rf "$TEMP_DIR"

echo -e "${GREEN}Monitoring setup completed successfully!${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Deploy the Haystack RAG application using Helm"
echo "2. Access Grafana at http://localhost:3000 to view dashboards"
