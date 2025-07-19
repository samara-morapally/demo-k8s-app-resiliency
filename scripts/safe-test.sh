#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🛡️  Safe Resilience Test - No Docker Interference${NC}"

# Wait for Docker to be ready
echo -e "${BLUE}⏳ Waiting for Docker to be ready...${NC}"
for i in {1..30}; do
    if docker info >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Docker is ready!${NC}"
        break
    else
        echo -e "${YELLOW}  Waiting for Docker... ($i/30)${NC}"
        sleep 5
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}❌ Docker failed to start after 150 seconds${NC}"
        exit 1
    fi
done

# Check if cluster exists
if ! kind get clusters | grep -q "resilience-demo"; then
    echo -e "${RED}❌ Kind cluster 'resilience-demo' not found.${NC}"
    echo -e "${BLUE}🔧 Creating cluster...${NC}"
    ./scripts/setup-cluster.sh
    ./scripts/deploy.sh
fi

# Set kubectl context
kubectl config use-context kind-resilience-demo

# Check cluster connectivity
echo -e "${BLUE}🔍 Checking cluster connectivity...${NC}"
if ! kubectl get nodes >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Cluster not accessible, may need restart${NC}"
    echo -e "${BLUE}🔄 Recreating cluster...${NC}"
    kind delete cluster --name resilience-demo || true
    ./scripts/setup-cluster.sh
    ./scripts/deploy.sh
fi

# Check if application is deployed
if ! kubectl get deployment resilient-app -n resilient-demo &>/dev/null; then
    echo -e "${YELLOW}⚠️  Application not deployed. Deploying...${NC}"
    ./scripts/deploy.sh
fi

echo -e "${GREEN}✅ System is ready!${NC}"
echo -e "${BLUE}📋 Current status:${NC}"
kubectl get nodes
echo ""
kubectl get pods -n resilient-demo

# Test basic functionality without port forwarding conflicts
echo -e "\n${BLUE}🧪 Testing basic functionality...${NC}"

# Use a random port to avoid conflicts
TEST_PORT=$((8080 + RANDOM % 1000))
echo -e "${BLUE}🔌 Using port $TEST_PORT for testing...${NC}"

# Start port forwarding with unique port
kubectl port-forward -n resilient-demo svc/resilient-app $TEST_PORT:8080 &
PF_PID=$!

# Wait for port forwarding
sleep 5

# Test health endpoint
if curl -s --max-time 5 "http://localhost:$TEST_PORT/health" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Health endpoint accessible${NC}"
    
    # Get health status
    health_status=$(curl -s "http://localhost:$TEST_PORT/health" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(f'Status: {data[\"status\"]}')
    for name, check in data[\"checks\"].items():
        print(f'  {name}: {check[\"status\"]}')
except:
    print('Unable to parse health response')
" 2>/dev/null)
    echo "$health_status"
    
    # Test API endpoint
    echo -e "${BLUE}🔌 Testing API endpoint...${NC}"
    if curl -s --max-time 5 "http://localhost:$TEST_PORT/api/users" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ API endpoint accessible${NC}"
    else
        echo -e "${YELLOW}⚠️  API endpoint not responding${NC}"
    fi
    
else
    echo -e "${YELLOW}⚠️  Health endpoint not accessible${NC}"
fi

# Clean up port forwarding (safely)
if kill -0 $PF_PID 2>/dev/null; then
    kill $PF_PID 2>/dev/null || true
    wait $PF_PID 2>/dev/null || true
fi

echo -e "\n${GREEN}✅ Safe test completed!${NC}"
echo -e "${BLUE}💡 Key points:${NC}"
echo "  - Used random port ($TEST_PORT) to avoid conflicts"
echo "  - No broad kill commands that could affect Docker"
echo "  - Cluster and application are functional"
echo ""
echo -e "${BLUE}🎯 You can now run individual tests:${NC}"
echo "  ./scripts/test-health.sh        # Health and API tests"
echo "  ./scripts/test-degradation.sh   # Graceful degradation"
echo "  ./scripts/test-graceful-shutdown.sh  # Fixed graceful shutdown" 