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

echo -e "${BLUE}🚀 Setting up Kind cluster for resilience demo...${NC}"

# Check if Kind is installed
if ! command -v kind &> /dev/null; then
    echo -e "${RED}❌ Kind is not installed. Please install it first:${NC}"
    echo "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl is not installed. Please install it first:${NC}"
    echo "https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo -e "${RED}❌ Docker is not running. Please start Docker first.${NC}"
    exit 1
fi

# Create Kind cluster configuration
cat > /tmp/kind-config.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: resilience-demo
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 8080
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
- role: worker
- role: worker
EOF

# Delete existing cluster if it exists
if kind get clusters | grep -q "resilience-demo"; then
    echo -e "${YELLOW}⚠️  Existing cluster found. Deleting...${NC}"
    kind delete cluster --name resilience-demo
fi

# Create new cluster
echo -e "${BLUE}📦 Creating Kind cluster...${NC}"
kind create cluster --config /tmp/kind-config.yaml --wait 5m

# Wait for cluster to be ready
echo -e "${BLUE}⏳ Waiting for cluster to be ready...${NC}"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# Verify cluster is working
echo -e "${BLUE}🔍 Verifying cluster...${NC}"
kubectl cluster-info
kubectl get nodes

echo -e "${GREEN}✅ Kind cluster 'resilience-demo' is ready!${NC}"
echo -e "${BLUE}📝 Next steps:${NC}"
echo "  1. Run './scripts/deploy.sh' to deploy the application"
echo "  2. Run './scripts/test-health.sh' to test the application"
echo ""
echo -e "${YELLOW}💡 Useful commands:${NC}"
echo "  - kubectl get pods -n resilient-demo"
echo "  - kubectl logs -f deployment/resilient-app -n resilient-demo"
echo "  - kubectl port-forward -n resilient-demo svc/resilient-app 8080:8080"

# Clean up
rm -f /tmp/kind-config.yaml 