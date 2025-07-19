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

echo -e "${BLUE}🏥 Testing application health and functionality...${NC}"

# Check if cluster exists
if ! kind get clusters | grep -q "resilience-demo"; then
    echo -e "${RED}❌ Kind cluster 'resilience-demo' not found. Run './scripts/setup-cluster.sh' first.${NC}"
    exit 1
fi

# Set kubectl context
kubectl config use-context kind-resilience-demo

# Check if application is deployed
if ! kubectl get deployment resilient-app -n resilient-demo &>/dev/null; then
    echo -e "${RED}❌ Application not deployed. Run './scripts/deploy.sh' first.${NC}"
    exit 1
fi

# Start port forwarding in background
echo -e "${BLUE}🔌 Starting port forwarding...${NC}"
kubectl port-forward -n resilient-demo svc/resilient-app 8080:8080 &
PORT_FORWARD_PID=$!

# Function to cleanup port forwarding
cleanup() {
    if [ -n "${PORT_FORWARD_PID:-}" ]; then
        echo -e "\n${BLUE}🧹 Cleaning up port forwarding...${NC}"
        kill $PORT_FORWARD_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Wait for port forwarding to be ready
echo -e "${BLUE}⏳ Waiting for port forwarding to be ready...${NC}"
sleep 5

# Test functions
test_endpoint() {
    local endpoint=$1
    local expected_status=$2
    local description=$3
    
    echo -e "${BLUE}  Testing $description...${NC}"
    
    local status_code
    status_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080$endpoint" || echo "000")
    
    if [ "$status_code" = "$expected_status" ]; then
        echo -e "${GREEN}    ✅ $description: $status_code${NC}"
        return 0
    else
        echo -e "${RED}    ❌ $description: Expected $expected_status, got $status_code${NC}"
        return 1
    fi
}

test_endpoint_with_content() {
    local endpoint=$1
    local expected_status=$2
    local description=$3
    local expected_content=$4
    
    echo -e "${BLUE}  Testing $description...${NC}"
    
    local response
    local status_code
    response=$(curl -s -w "\n%{http_code}" "http://localhost:8080$endpoint" 2>/dev/null || echo -e "\n000")
    status_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" = "$expected_status" ]; then
        if [[ "$body" == *"$expected_content"* ]]; then
            echo -e "${GREEN}    ✅ $description: $status_code (content verified)${NC}"
            return 0
        else
            echo -e "${YELLOW}    ⚠️  $description: $status_code (unexpected content)${NC}"
            echo -e "${YELLOW}       Expected: $expected_content${NC}"
            echo -e "${YELLOW}       Got: $body${NC}"
            return 1
        fi
    else
        echo -e "${RED}    ❌ $description: Expected $expected_status, got $status_code${NC}"
        return 1
    fi
}

# Start testing
echo -e "${BLUE}🧪 Running health and functionality tests...${NC}"

# Test health endpoints
echo -e "\n${BLUE}🏥 Health Endpoints:${NC}"
test_endpoint "/health" "200" "Health check endpoint"
test_endpoint "/ready" "200" "Readiness check endpoint"  
test_endpoint "/startup" "200" "Startup check endpoint"

# Test API endpoints
echo -e "\n${BLUE}🔌 API Endpoints:${NC}"
test_endpoint_with_content "/api/users" "200" "Get users endpoint" "email"
test_endpoint_with_content "/api/users/1" "200" "Get user by ID endpoint" "email"
test_endpoint_with_content "/api/status" "200" "System status endpoint" "health"

# Test metrics endpoint
echo -e "\n${BLUE}📊 Metrics Endpoint:${NC}"
test_endpoint_with_content "/metrics" "200" "Prometheus metrics endpoint" "http_requests_total"

# Test creating a user
echo -e "\n${BLUE}👤 User Creation Test:${NC}"
echo -e "${BLUE}  Testing user creation...${NC}"
create_response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"Test User","email":"test@example.com"}' \
    "http://localhost:8080/api/users" 2>/dev/null || echo -e "\n000")

create_status=$(echo "$create_response" | tail -1)
create_body=$(echo "$create_response" | sed '$d')

if [ "$create_status" = "201" ]; then
    echo -e "${GREEN}    ✅ User creation: $create_status${NC}"
    echo -e "${GREEN}    Created user: $create_body${NC}"
else
    echo -e "${YELLOW}    ⚠️  User creation: $create_status (may fail if user exists)${NC}"
fi

# Test detailed health information
echo -e "\n${BLUE}🔍 Detailed Health Information:${NC}"
health_response=$(curl -s "http://localhost:8080/health" 2>/dev/null || echo "{}")
echo -e "${BLUE}Health Response:${NC}"
echo "$health_response" | python3 -m json.tool 2>/dev/null || echo "$health_response"

# Test system status
echo -e "\n${BLUE}📈 System Status Information:${NC}"
status_response=$(curl -s "http://localhost:8080/api/status" 2>/dev/null || echo "{}")
echo -e "${BLUE}Status Response:${NC}"
echo "$status_response" | python3 -m json.tool 2>/dev/null || echo "$status_response"

# Check Kubernetes resources
echo -e "\n${BLUE}☸️  Kubernetes Resources:${NC}"
echo -e "${BLUE}  Pods:${NC}"
kubectl get pods -n resilient-demo -o wide

echo -e "\n${BLUE}  Services:${NC}"
kubectl get services -n resilient-demo

echo -e "\n${BLUE}  Deployment Status:${NC}"
kubectl get deployment resilient-app -n resilient-demo -o wide

# Check pod logs for any errors
echo -e "\n${BLUE}📋 Recent Pod Logs:${NC}"
POD_NAME=$(kubectl get pods -n resilient-demo -l app.kubernetes.io/name=resilient-app -o jsonpath="{.items[0].metadata.name}")
echo -e "${BLUE}  Last 10 log lines from $POD_NAME:${NC}"
kubectl logs -n resilient-demo "$POD_NAME" --tail=10

echo -e "\n${GREEN}✅ Health and functionality tests completed!${NC}"
echo -e "${BLUE}💡 To continue testing resilience:${NC}"
echo "  - Run './scripts/test-graceful-shutdown.sh' to test graceful shutdown"
echo "  - Run './scripts/test-degradation.sh' to test graceful degradation"
echo "  - Run './scripts/chaos-test.sh' for comprehensive chaos testing" 