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

echo -e "${BLUE}🔨 Building resilient application...${NC}"

# Check if Kind cluster exists
if ! kind get clusters | grep -q "resilience-demo"; then
    echo -e "${RED}❌ Kind cluster 'resilience-demo' not found. Run './scripts/setup-cluster.sh' first.${NC}"
    exit 1
fi

# Navigate to application directory
cd "$PROJECT_ROOT/resilient-app"

# Check if go.mod exists
if [ ! -f "go.mod" ]; then
    echo -e "${RED}❌ go.mod not found. Please ensure you're in the correct directory.${NC}"
    exit 1
fi

# Resolve Go dependencies
echo -e "${BLUE}📦 Resolving Go dependencies...${NC}"
go mod tidy
go mod download

# Verify dependencies
echo -e "${BLUE}🔍 Verifying dependencies...${NC}"
go mod verify

echo -e "${GREEN}✅ Go dependencies resolved${NC}"

# Build Docker image
echo -e "${BLUE}🐳 Building Docker image...${NC}"
docker build -t resilient-app:latest .

# Verify image was built
if ! docker images | grep -q "resilient-app.*latest"; then
    echo -e "${RED}❌ Failed to build Docker image${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Application compiled successfully${NC}"
echo -e "${GREEN}✅ Docker image built: resilient-app:latest${NC}"

# Load image into Kind cluster
echo -e "${BLUE}📦 Loading image into Kind cluster...${NC}"
kind load docker-image resilient-app:latest --name resilience-demo

# Verify image is loaded in Kind cluster
echo -e "${BLUE}🔍 Verifying image in Kind cluster...${NC}"
if docker exec -it resilience-demo-control-plane crictl images | grep -q "resilient-app"; then
    echo -e "${GREEN}✅ Image loaded into Kind cluster${NC}"
else
    echo -e "${YELLOW}⚠️  Image may not be fully loaded yet${NC}"
fi

echo -e "${GREEN}✅ Build completed successfully!${NC}"
echo ""
echo -e "${BLUE}💡 Next steps:${NC}"
echo "  Run './scripts/deploy.sh' to deploy the application to Kubernetes" 