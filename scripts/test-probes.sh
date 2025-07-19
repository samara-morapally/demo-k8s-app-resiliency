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

echo -e "${BLUE}🔍 Testing Kubernetes Probe Behavior${NC}"

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

# Function to test probe endpoint
test_probe() {
    local endpoint=$1
    local probe_name=$2
    local expected_behavior=$3
    
    echo -e "\n${BLUE}🔍 Testing $probe_name Probe${NC}"
    echo -e "${BLUE}  Endpoint: $endpoint${NC}"
    echo -e "${BLUE}  Expected: $expected_behavior${NC}"
    
    local success_count=0
    local total_tests=5
    
    for i in $(seq 1 $total_tests); do
        local status_code
        local response_time
        
        start_time=$(date +%s%N)
        status_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080$endpoint" 2>/dev/null || echo "000")
        end_time=$(date +%s%N)
        
        response_time=$(( (end_time - start_time) / 1000000 )) # Convert to milliseconds
        
        echo -e "${BLUE}    Test $i: Status=$status_code, Time=${response_time}ms${NC}"
        
        if [ "$status_code" = "200" ] || [ "$status_code" = "503" ]; then
            ((success_count++))
        fi
        
        sleep 1
    done
    
    local success_rate=$(( (success_count * 100) / total_tests ))
    
    if [ $success_rate -ge 80 ]; then
        echo -e "${GREEN}  ✅ $probe_name probe: ${success_rate}% success rate${NC}"
    else
        echo -e "${YELLOW}  ⚠️  $probe_name probe: ${success_rate}% success rate${NC}"
    fi
}

# Test each probe type
test_probe "/startup" "Startup" "Should return 200 after initialization"
test_probe "/ready" "Readiness" "Should return 200 when ready to serve traffic"
test_probe "/health" "Liveness" "Should return 200 when healthy, 503 when degraded"

# Test probe behavior during application startup simulation
echo -e "\n${BLUE}🚀 Testing Probe Behavior During Pod Restart${NC}"

# Get current pod
CURRENT_POD=$(kubectl get pods -n resilient-demo -l app.kubernetes.io/name=resilient-app -o jsonpath="{.items[0].metadata.name}")
echo -e "${BLUE}  Current pod: $CURRENT_POD${NC}"

# Delete pod to trigger restart
echo -e "${BLUE}  Deleting pod to test startup behavior...${NC}"
kubectl delete pod "$CURRENT_POD" -n resilient-demo &

# Wait for new pod to be created
echo -e "${BLUE}  Waiting for new pod to be created...${NC}"
sleep 10

# Get new pod name
NEW_POD=$(kubectl get pods -n resilient-demo -l app.kubernetes.io/name=resilient-app -o jsonpath="{.items[0].metadata.name}")
echo -e "${BLUE}  New pod: $NEW_POD${NC}"

# Monitor probe status during startup
echo -e "${BLUE}  Monitoring probe status during startup...${NC}"

for i in {1..10}; do
    # Get pod conditions
    startup_ready=$(kubectl get pod "$NEW_POD" -n resilient-demo -o jsonpath="{.status.conditions[?(@.type=='PodReadyCondition')].status}" 2>/dev/null || echo "Unknown")
    containers_ready=$(kubectl get pod "$NEW_POD" -n resilient-demo -o jsonpath="{.status.conditions[?(@.type=='ContainersReady')].status}" 2>/dev/null || echo "Unknown")
    pod_ready=$(kubectl get pod "$NEW_POD" -n resilient-demo -o jsonpath="{.status.conditions[?(@.type=='Ready')].status}" 2>/dev/null || echo "Unknown")
    
    echo -e "${BLUE}    Check $i: ContainersReady=$containers_ready, PodReady=$pod_ready${NC}"
    
    # Test probe endpoints
    startup_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/startup" 2>/dev/null || echo "000")
    ready_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/ready" 2>/dev/null || echo "000")
    health_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/health" 2>/dev/null || echo "000")
    
    echo -e "${BLUE}      Probe responses: startup=$startup_status, ready=$ready_status, health=$health_status${NC}"
    
    if [ "$pod_ready" = "True" ]; then
        echo -e "${GREEN}  ✅ Pod became ready after $i checks${NC}"
        break
    fi
    
    sleep 3
done

# Test probe configuration verification
echo -e "\n${BLUE}📋 Verifying Probe Configurations${NC}"

# Get probe configurations from deployment
echo -e "${BLUE}  Startup Probe Configuration:${NC}"
kubectl get deployment resilient-app -n resilient-demo -o jsonpath="{.spec.template.spec.containers[0].startupProbe}" | python3 -m json.tool 2>/dev/null || echo "    Not configured"

echo -e "\n${BLUE}  Readiness Probe Configuration:${NC}"
kubectl get deployment resilient-app -n resilient-demo -o jsonpath="{.spec.template.spec.containers[0].readinessProbe}" | python3 -m json.tool 2>/dev/null || echo "    Not configured"

echo -e "\n${BLUE}  Liveness Probe Configuration:${NC}"
kubectl get deployment resilient-app -n resilient-demo -o jsonpath="{.spec.template.spec.containers[0].livenessProbe}" | python3 -m json.tool 2>/dev/null || echo "    Not configured"

# Test probe behavior under load
echo -e "\n${BLUE}⚡ Testing Probe Behavior Under Load${NC}"

# Generate some load while testing probes
echo -e "${BLUE}  Generating background load...${NC}"
for i in {1..20}; do
    curl -s -o /dev/null "http://localhost:8080/api/users" &
done

# Test probes under load
sleep 2
test_probe "/health" "Liveness (under load)" "Should remain responsive under load"

# Wait for background requests to complete
wait

# Test probe response times
echo -e "\n${BLUE}⏱️  Testing Probe Response Times${NC}"

for endpoint in "/startup" "/ready" "/health"; do
    echo -e "${BLUE}  Testing $endpoint response time...${NC}"
    
    total_time=0
    test_count=5
    
    for i in $(seq 1 $test_count); do
        start_time=$(date +%s%N)
        curl -s -o /dev/null "http://localhost:8080$endpoint" 2>/dev/null
        end_time=$(date +%s%N)
        
        response_time=$(( (end_time - start_time) / 1000000 ))
        total_time=$((total_time + response_time))
        
        echo -e "${BLUE}    Test $i: ${response_time}ms${NC}"
    done
    
    average_time=$((total_time / test_count))
    echo -e "${BLUE}    Average response time: ${average_time}ms${NC}"
    
    if [ $average_time -lt 100 ]; then
        echo -e "${GREEN}    ✅ Good response time${NC}"
    elif [ $average_time -lt 500 ]; then
        echo -e "${YELLOW}    ⚠️  Acceptable response time${NC}"
    else
        echo -e "${RED}    ❌ Slow response time${NC}"
    fi
done

# Final status check
echo -e "\n${BLUE}📊 Final Probe Status Summary${NC}"
kubectl get pods -n resilient-demo -l app.kubernetes.io/name=resilient-app

echo -e "\n${GREEN}✅ Kubernetes probe testing completed!${NC}"
echo -e "${BLUE}💡 Key findings:${NC}"
echo "  - Startup probes help Kubernetes know when the app is initialized"
echo "  - Readiness probes control traffic routing"
echo "  - Liveness probes determine when to restart containers"
echo "  - All probes should be lightweight and fast"
echo "  - Probe configurations should match application startup times" 