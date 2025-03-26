#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Cleaning up Haystack RAG Application deployment...${NC}"

# Delete minikube cluster
echo -e "${YELLOW}Deleting Minikube cluster...${NC}"
minikube delete
echo -e "${GREEN}Minikube cluster deleted.${NC}"

# Find and display port-forward processes
echo -e "${YELLOW}Finding port-forward processes...${NC}"
port_forward_pids=$(ps aux | grep "[k]ubectl.*port-forward" | awk '{print $2}')
if [ -n "$port_forward_pids" ]; then
    echo -e "${GREEN}Found port-forward processes with PIDs:${NC}"
    echo "$port_forward_pids"
else
    echo -e "${YELLOW}No port-forward processes found.${NC}"
fi

echo -e "${GREEN}Cleanup completed!${NC}"
