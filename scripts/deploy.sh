#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}🚀 Deploying resilient application...${NC}"

# Check if Kind cluster exists
if ! kind get clusters | grep -q "resilience-demo"; then
    echo -e "${RED}❌ Kind cluster 'resilience-demo' not found. Run './scripts/setup-cluster.sh' first.${NC}"
    exit 1
fi

# Set kubectl context to Kind cluster
kubectl config use-context kind-resilience-demo

# Check if Docker image exists
if ! docker images | grep -q "resilient-app.*latest"; then
    echo -e "${YELLOW}⚠️  Docker image 'resilient-app:latest' not found.${NC}"
    echo -e "${BLUE}🔨 Building application first...${NC}"
    "$SCRIPT_DIR/build-and-load.sh"
else
    echo -e "${GREEN}✅ Docker image found: resilient-app:latest${NC}"
    # Ensure image is loaded in Kind cluster
    echo -e "${BLUE}📦 Ensuring image is loaded in Kind cluster...${NC}"
    kind load docker-image resilient-app:latest --name resilience-demo
fi

# Deploy to Kubernetes
echo -e "${BLUE}🚢 Deploying to Kubernetes...${NC}"
cd "$PROJECT_ROOT"

# Apply manifests in order
echo -e "${BLUE}  📋 Creating namespace...${NC}"
kubectl apply -f k8s/namespace.yaml

echo -e "${BLUE}  🔧 Creating configuration...${NC}"
kubectl apply -f k8s/configmap.yaml

echo -e "${BLUE}  🗄️  Deploying database...${NC}"
kubectl apply -f k8s/postgres.yaml

echo -e "${BLUE}  ⏳ Waiting for database to be ready...${NC}"
kubectl wait --for=condition=Available deployment/postgres -n resilient-demo --timeout=300s

echo -e "${BLUE}  🚀 Deploying application...${NC}"
kubectl apply -f k8s/deployment.yaml

echo -e "${BLUE}  ⏳ Waiting for application to be ready...${NC}"
kubectl wait --for=condition=Available deployment/resilient-app -n resilient-demo --timeout=300s

# Verify deployment
echo -e "${BLUE}🔍 Verifying deployment...${NC}"
kubectl get pods -n resilient-demo

# Apply services
echo -e "${BLUE}  🌐 Creating services...${NC}"
kubectl apply -f k8s/service.yaml

echo -e "${GREEN}✅ Deployment completed successfully!${NC}"
echo ""
echo -e "${BLUE}📊 Current status:${NC}"
kubectl get all -n resilient-demo

echo ""
echo -e "${BLUE}💡 Next steps:${NC}"
echo "  Run './scripts/test-health.sh' to verify application health"
echo "  Run './scripts/test-graceful-shutdown.sh' to test graceful shutdown"
echo "  Run './scripts/test-degradation.sh' to test graceful degradation"
echo "  Run './scripts/chaos-test.sh' for comprehensive chaos testing" 