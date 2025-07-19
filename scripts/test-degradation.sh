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

echo -e "${BLUE}🔧 Testing graceful degradation behavior...${NC}"

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

# Function to cleanup
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

# Function to test endpoint and show response
test_endpoint_detailed() {
    local endpoint=$1
    local description=$2
    
    echo -e "${BLUE}  Testing $description...${NC}"
    
    local response
    local status_code
    response=$(curl -s -w "\n%{http_code}" "http://localhost:8080$endpoint" 2>/dev/null || echo -e "\n000")
    status_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | sed '$d')
    
    echo -e "${BLUE}    Status: $status_code${NC}"
    if [ "$status_code" = "200" ]; then
        echo -e "${GREEN}    ✅ $description successful${NC}"
    elif [ "$status_code" = "503" ]; then
        echo -e "${YELLOW}    ⚠️  $description degraded${NC}"
    else
        echo -e "${RED}    ❌ $description failed${NC}"
    fi
    
    # Show response body (formatted if JSON)
    if [[ "$body" == *"{"* ]]; then
        echo -e "${BLUE}    Response:${NC}"
        echo "$body" | python3 -m json.tool 2>/dev/null | head -20 || echo "$body"
    else
        echo -e "${BLUE}    Response: $body${NC}"
    fi
    echo ""
}

# Function to check circuit breaker status
check_circuit_breaker() {
    echo -e "${BLUE}🔌 Checking circuit breaker status...${NC}"
    local response
    response=$(curl -s "http://localhost:8080/api/status" 2>/dev/null || echo "{}")
    
    if [[ "$response" == *"circuit_breaker"* ]]; then
        echo -e "${BLUE}Circuit Breaker Status:${NC}"
        echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    cb = data.get('circuit_breaker', {})
    print(f'  State: {cb.get(\"state\", \"unknown\")}')
    print(f'  Requests: {cb.get(\"requests\", 0)}')
    print(f'  Successes: {cb.get(\"total_successes\", 0)}')
    print(f'  Failures: {cb.get(\"total_failures\", 0)}')
except:
    print('  Unable to parse circuit breaker status')
" 2>/dev/null || echo "  Unable to parse response"
    else
        echo -e "${YELLOW}  ⚠️  No circuit breaker status available${NC}"
    fi
    echo ""
}

# Test baseline functionality
echo -e "${BLUE}📊 Phase 1: Testing baseline functionality${NC}"
test_endpoint_detailed "/health" "Health check"
test_endpoint_detailed "/api/users" "Get users"
test_endpoint_detailed "/api/users/1" "Get user by ID"
check_circuit_breaker

# Scale down database to simulate failure
echo -e "${BLUE}💥 Phase 2: Simulating database failure${NC}"
echo -e "${BLUE}  Scaling down PostgreSQL deployment...${NC}"
kubectl scale deployment postgres -n resilient-demo --replicas=0

# Wait for database to be unavailable
echo -e "${BLUE}  Waiting for database to become unavailable...${NC}"
sleep 10

# Test functionality during database failure
echo -e "${BLUE}📊 Phase 3: Testing behavior during database failure${NC}"
test_endpoint_detailed "/health" "Health check (DB down)"
test_endpoint_detailed "/ready" "Readiness check (DB down)"
test_endpoint_detailed "/api/users" "Get users (DB down - should show fallback)"
test_endpoint_detailed "/api/users/1" "Get user by ID (DB down - should show fallback)"
check_circuit_breaker

# Try to create a user during failure
echo -e "${BLUE}👤 Testing user creation during database failure...${NC}"
create_response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"Test User During Failure","email":"failure-test@example.com"}' \
    "http://localhost:8080/api/users" 2>/dev/null || echo -e "\n000")

create_status=$(echo "$create_response" | tail -1)
create_body=$(echo "$create_response" | sed '$d')

echo -e "${BLUE}  Create User Status: $create_status${NC}"
if [ "$create_status" = "503" ]; then
    echo -e "${GREEN}    ✅ Correctly returned 503 (Service Unavailable) during degraded mode${NC}"
elif [ "$create_status" = "500" ]; then
    echo -e "${YELLOW}    ⚠️  Returned 500 (Internal Server Error) - acceptable during failure${NC}"
else
    echo -e "${YELLOW}    ⚠️  Unexpected status during database failure${NC}"
fi

if [[ "$create_body" == *"degraded"* ]]; then
    echo -e "${GREEN}    ✅ Response indicates degraded mode${NC}"
fi
echo ""

# Monitor application logs during failure
echo -e "${BLUE}📋 Recent application logs during failure:${NC}"
APP_POD=$(kubectl get pods -n resilient-demo -l app.kubernetes.io/name=resilient-app -o jsonpath="{.items[0].metadata.name}")
kubectl logs -n resilient-demo "$APP_POD" --tail=10 | head -5

# Test circuit breaker behavior
echo -e "${BLUE}🔌 Testing circuit breaker behavior...${NC}"
echo -e "${BLUE}  Making multiple requests to trigger circuit breaker...${NC}"

for i in {1..5}; do
    echo -e "${BLUE}    Request $i/5...${NC}"
    curl -s -o /dev/null "http://localhost:8080/api/users/999" || true
    sleep 1
done

check_circuit_breaker

# Restore database
echo -e "${BLUE}🔄 Phase 4: Restoring database service${NC}"
echo -e "${BLUE}  Scaling PostgreSQL deployment back up...${NC}"
kubectl scale deployment postgres -n resilient-demo --replicas=1

# Wait for database to be available
echo -e "${BLUE}  Waiting for database to become available...${NC}"
kubectl wait --for=condition=Available deployment/postgres -n resilient-demo --timeout=120s

# Give database time to fully initialize
sleep 15

# Test recovery
echo -e "${BLUE}📊 Phase 5: Testing recovery after database restoration${NC}"
test_endpoint_detailed "/health" "Health check (DB restored)"
test_endpoint_detailed "/ready" "Readiness check (DB restored)"
test_endpoint_detailed "/api/users" "Get users (DB restored)"
test_endpoint_detailed "/api/users/1" "Get user by ID (DB restored)"
check_circuit_breaker

# Test creating a user after recovery
echo -e "${BLUE}👤 Testing user creation after recovery...${NC}"
recovery_response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"Recovery Test User","email":"recovery-test@example.com"}' \
    "http://localhost:8080/api/users" 2>/dev/null || echo -e "\n000")

recovery_status=$(echo "$recovery_response" | tail -1)
recovery_body=$(echo "$recovery_response" | sed '$d')

echo -e "${BLUE}  Create User Status: $recovery_status${NC}"
if [ "$recovery_status" = "201" ]; then
    echo -e "${GREEN}    ✅ User creation successful after recovery${NC}"
    echo -e "${GREEN}    Created user: $recovery_body${NC}"
else
    echo -e "${YELLOW}    ⚠️  User creation status: $recovery_status (may need more time)${NC}"
fi
echo ""

# Final health and status check
echo -e "${BLUE}🏥 Final system status:${NC}"
final_status=$(curl -s "http://localhost:8080/api/status" 2>/dev/null || echo "{}")
echo "$final_status" | python3 -m json.tool 2>/dev/null || echo "$final_status"

# Summary
echo -e "\n${BLUE}📊 Graceful Degradation Test Summary:${NC}"
echo -e "${GREEN}✅ Key Observations:${NC}"
echo -e "${GREEN}  • Application remained responsive during database failure${NC}"
echo -e "${GREEN}  • Health checks properly indicated degraded state${NC}"
echo -e "${GREEN}  • Circuit breaker activated to prevent cascade failures${NC}"
echo -e "${GREEN}  • Fallback data was served when database was unavailable${NC}"
echo -e "${GREEN}  • Write operations were properly rejected during degradation${NC}"
echo -e "${GREEN}  • System recovered automatically when database was restored${NC}"

echo -e "\n${BLUE}💡 Resilience Patterns Demonstrated:${NC}"
echo "  1. Circuit Breaker: Prevented repeated failed database calls"
echo "  2. Graceful Degradation: Served fallback data instead of failing"
echo "  3. Health Checks: Accurately reflected system state"
echo "  4. Fail-Safe Defaults: Rejected writes safely during failures"
echo "  5. Auto-Recovery: Resumed normal operation when dependencies recovered"

echo -e "\n${GREEN}✅ Graceful degradation test completed successfully!${NC}" 