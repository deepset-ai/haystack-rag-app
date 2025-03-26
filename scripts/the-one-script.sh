#!/bin/bash

# Master script for orchestrating the complete application stack setup and deployment

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# State file to track progress
STATE_FILE=".deployment-state"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if a stage has been completed
is_stage_completed() {
    local stage=$1
    [[ -f "$STATE_FILE" ]] && grep -q "^$stage$" "$STATE_FILE"
}

# Mark a stage as completed
mark_stage_completed() {
    local stage=$1
    echo "$stage" >> "$STATE_FILE"
}

# Execute a stage with error handling
execute_stage() {
    local stage=$1
    local command=$2
    local message=$3

    if is_stage_completed "$stage"; then
        log_info "Stage '$stage' has already been completed."
        return 0
    fi

    log_info "$message"
    
    if ! $command; then
        log_error "Failed to execute stage: $stage"
        return 1
    fi

    mark_stage_completed "$stage"
    log_success "Completed stage: $stage"
}

# Initialize Minikube environment
init_minikube() {
    execute_stage "minikube" \
        "./setup-minikube.sh" \
        "Initializing Minikube cluster..."
}

# Setup container images
setup_images() {
    execute_stage "images" \
        "./setup-images-for-minikube.sh" \
        "Setting up container images in Minikube..."
}

# Configure Vault and Consul
setup_vault_consul() {
    execute_stage "vault-consul" \
        "./setup-vault-consul.sh" \
        "Configuring Vault and Consul services..."
}

# Setup monitoring stack
setup_monitoring() {
    execute_stage "monitoring" \
        "./setup-monitoring.sh" \
        "Deploying monitoring infrastructure..."
}

# Deploy application
deploy_app() {
    execute_stage "deploy" \
        "./deploy.sh" \
        "Deploying application components..."
}

# Cleanup resources
cleanup_resources() {
    log_warning "This will remove all deployed resources and configurations."
    read -p "Are you sure you want to proceed? (yes/no) " answer
    
    if [[ "$answer" != "yes" ]]; then
        log_info "Operation cancelled."
        return 0
    fi

    log_info "Starting cleanup process..."
    
    if ! ./cleanup.sh; then
        log_error "Cleanup failed. Check the logs for details."
        return 1
    fi

    rm -f "$STATE_FILE"
    log_success "Cleanup completed successfully."
}

# Main script logic
case "$1" in
    "forge")
        log_info "Starting complete deployment sequence..."
        
        # Execute all stages in order
        init_minikube && \
        setup_images && \
        setup_vault_consul && \
        setup_monitoring && \
        deploy_app

        if [[ $? -eq 0 ]]; then
            log_success "Deployment completed successfully!"
        else
            log_error "Deployment failed. Check the logs above for details."
            exit 1
        fi
        ;;

    "destroy-ring")
        cleanup_resources
        ;;

    *)
        echo "Usage: $0 {forge|destroy-ring}"
        echo
        echo "Commands:"
        echo "  forge        - Setup and deploy the complete application stack"
        echo "  destroy-ring - Clean up and remove all deployed resources"
        exit 1
        ;;
esac
