# 🚀 End-to-End Kubernetes Resilience Demo Guide

*A comprehensive step-by-step walkthrough for building and testing resilient applications in Kubernetes*

---

## 🎯 **What You'll Build**

By the end of this demo, you'll have a production-ready Go application that demonstrates:
- **Graceful shutdown** with proper OS signal handling
- **Circuit breaker pattern** for external service failures  
- **Graceful degradation** when dependencies are unavailable
- **Comprehensive health checks** (startup, readiness, liveness)
- **Structured logging** and **Prometheus metrics**
- **Kubernetes-native resilience** with resource limits and pod disruption budgets

---

## 📋 **Prerequisites**

```bash
# Required tools
docker --version          # Docker Desktop 4.0+
kind --version            # Kind v0.20.0+  
kubectl version --client  # kubectl v1.27+
go version                # Go 1.21+
```

---

## 🛠️ **Step 1: Set Up Kind Cluster**

### **Command:**
```bash
# Clone the complete demo repository
git clone <your-github-repo>/demo-k8s-app-resiliency
cd demo-k8s-app-resiliency

# Create Kind cluster with our configuration
./scripts/setup-cluster.sh
```

### **What This Does:**
- Creates a **3-node Kind cluster** (1 control plane + 2 workers)
- Configures **ingress-ready** setup for load balancing
- Sets up **proper networking** for local development
- Installs **metrics-server** for resource monitoring

### **What to Expect:**
```bash
✅ Creating Kind cluster: resilience-demo
✅ Cluster created successfully
✅ Installing metrics-server...
✅ Cluster setup completed!

# Verify cluster nodes
kubectl get nodes
NAME                            STATUS   ROLES           AGE   VERSION
resilience-demo-control-plane   Ready    control-plane   2m    v1.27.3
resilience-demo-worker          Ready    <none>          2m    v1.27.3
resilience-demo-worker2         Ready    <none>          2m    v1.27.3
```

### **What to Look For:**
- ✅ All 3 nodes show `STATUS: Ready`
- ✅ Control plane and worker nodes are distinct
- ✅ kubectl context switched to `kind-resilience-demo`

---

## 🏗️ **Step 2: Build the Resilient Go Application**

### **Command:**
```bash
# Build and load the application image
./scripts/build-and-load.sh
```

### **What This Does:**
- **Compiles** the Go application with all dependencies
- **Creates multi-stage Docker image** for security and size optimization
- **Loads image** directly into Kind cluster (no registry needed)
- **Validates** the build with dependency checks

### **Application Architecture:**
```go
// Key resilience patterns implemented:
- Circuit Breaker (github.com/sony/gobreaker)
- Structured Logging (go.uber.org/zap)  
- Health Checks (custom implementation)
- Graceful Shutdown (OS signal handling)
- Prometheus Metrics (github.com/prometheus/client_golang)
```

### **What to Expect:**
```bash
🔨 Building resilient application...
✅ Go dependencies resolved
✅ Application compiled successfully  
✅ Docker image built: resilient-app:latest
✅ Image loaded into Kind cluster
✅ Build completed successfully!
```

### **What to Look For:**
- ✅ No compilation errors or missing dependencies
- ✅ Docker image size optimized (multi-stage build)
- ✅ Image available in Kind cluster: `docker exec -it resilience-demo-control-plane crictl images`

---

## 📦 **Step 3: Deploy Application with Resilience Configurations**

### **Command:**
```bash
# Deploy complete application stack
./scripts/deploy.sh
```

### **What This Deploys:**
1. **PostgreSQL database** with persistent storage
2. **Resilient application** with 3 replicas
3. **Services** for internal communication
4. **Resource limits** and requests
5. **Pod disruption budgets**
6. **Security contexts** (non-root, read-only filesystem)

### **Key Kubernetes Resilience Features:**
```yaml
# Resource Management
resources:
  requests: { memory: "64Mi", cpu: "100m" }
  limits: { memory: "128Mi", cpu: "200m" }

# Health Probes  
livenessProbe:
  httpGet: { path: "/health", port: 8080 }
readinessProbe:
  httpGet: { path: "/ready", port: 8080 }
startupProbe:
  httpGet: { path: "/startup", port: 8080 }

# Graceful Shutdown
terminationGracePeriodSeconds: 30
lifecycle:
  preStop:
    exec: { command: ["/bin/sh", "-c", "sleep 10"] }
```

### **What to Expect:**
```bash
🚀 Deploying resilient application...
✅ Namespace created: resilient-demo
✅ PostgreSQL deployed and ready
✅ Application deployed: 3/3 replicas ready
✅ Services created and accessible
✅ Deployment completed successfully!

# Pod status after deployment
kubectl get pods -n resilient-demo
NAME                            READY   STATUS    RESTARTS   AGE
postgres-b8b766499-6jhxw        1/1     Running   0          2m
resilient-app-b886bbbfc-mqdd8   1/1     Running   0          1m
resilient-app-b886bbbfc-rmjvm   1/1     Running   0          1m  
resilient-app-b886bbbfc-tk6jk   1/1     Running   0          1m
```

### **What to Look For:**
- ✅ All pods show `READY: 1/1` and `STATUS: Running`
- ✅ Zero restarts (indicates healthy startup)
- ✅ Pods distributed across different nodes
- ✅ Services have assigned cluster IPs

---

## 🏥 **Step 4: Verify Application Health and Functionality**

### **Command:**
```bash
# Comprehensive health and functionality test
./scripts/test-health.sh
```

### **What This Tests:**
1. **Health endpoints**: `/health`, `/ready`, `/startup`
2. **API functionality**: User CRUD operations
3. **Database connectivity**: PostgreSQL integration
4. **Circuit breaker state**: Monitoring request patterns
5. **Metrics collection**: Prometheus endpoint validation

### **What to Expect:**
```bash
🏥 Testing application health and functionality...

🏥 Health Endpoints:
    ✅ Health check endpoint: 200
    ✅ Readiness check endpoint: 200  
    ✅ Startup check endpoint: 200

🔌 API Endpoints:
    ✅ Get users endpoint: 200 (content verified)
    ✅ Get user by ID endpoint: 200 (content verified)
    ✅ System status endpoint: 200 (content verified)

📊 Metrics Endpoint:
    ✅ Prometheus metrics endpoint: 200 (content verified)

🔍 Detailed Health Information:
{
    "status": "healthy",
    "checks": {
        "database": { "status": "healthy", "message": "Database connection successful" },
        "memory": { "status": "healthy", "message": "Memory usage within normal limits" },
        "features": { "status": "healthy", "message": "Features enabled: graceful_degradation, circuit_breaker, metrics" }
    }
}
```

### **What to Look For:**
- ✅ All HTTP responses return `200 OK`
- ✅ Database connection is healthy
- ✅ Circuit breaker is in `closed` state (accepting requests)
- ✅ All resilience features are enabled
- ✅ Prometheus metrics are being collected

---

## 💥 **Step 5: Test Resilience - Pod Deletion**

### **Command:**
```bash
# Test pod recovery and load balancing
kubectl delete pod -n resilient-demo -l app.kubernetes.io/name=resilient-app --wait=false

# Monitor recovery
kubectl get pods -n resilient-demo -w
```

### **What This Tests:**
- **Kubernetes self-healing**: Automatic pod recreation
- **Load balancing**: Traffic distribution during pod restart  
- **Zero-downtime deployment**: Service availability during disruption
- **Graceful shutdown**: Proper SIGTERM handling

### **What to Expect:**
```bash
# Immediate response
pod "resilient-app-b886bbbfc-mqdd8" deleted

# Watching pod status
NAME                            READY   STATUS        RESTARTS   AGE
resilient-app-b886bbbfc-mqdd8   1/1     Terminating   0          5m
resilient-app-b886bbbfc-rmjvm   1/1     Running       0          5m
resilient-app-b886bbbfc-tk6jk   1/1     Running       0          5m
resilient-app-b886bbbfc-xyz123  0/1     Pending       0          0s
resilient-app-b886bbbfc-xyz123  0/1     ContainerCreating   0    1s
resilient-app-b886bbbfc-xyz123  1/1     Running       0          15s
resilient-app-b886bbbfc-mqdd8   0/1     Terminating   0          5m
```

### **What to Look For:**
- ✅ **New pod created immediately** when old pod starts terminating
- ✅ **Graceful termination**: Old pod stays in `Terminating` for ~10-30 seconds
- ✅ **Service continuity**: 2/3 pods remain available during transition
- ✅ **Quick recovery**: New pod reaches `Running` state within 30 seconds

---

## 🔄 **Step 6: Test Graceful Shutdown**

### **Command:**
```bash
# Test proper SIGTERM handling
./scripts/test-graceful-shutdown.sh
```

### **What This Tests:**
- **OS signal handling**: Proper SIGTERM response
- **Connection draining**: Existing requests complete gracefully
- **Resource cleanup**: Database connections, goroutines properly closed
- **Kubernetes lifecycle**: preStop hooks and termination grace period

### **What to Expect:**
```bash
🛑 Testing graceful shutdown...
✅ Port forwarding established
📊 Initial health check: healthy

🔄 Sending SIGTERM to pod resilient-app-b886bbbfc-rmjvm...
⏳ Monitoring graceful shutdown process...

📊 Pod Status Timeline:
  t+0s:  STATUS: Running    → SIGTERM sent
  t+2s:  STATUS: Running    → App stopping gracefully  
  t+8s:  STATUS: Terminating → Connections draining
  t+12s: STATUS: Terminating → Cleanup in progress
  t+15s: Pod terminated successfully

✅ Graceful shutdown completed in 15 seconds
✅ New pod started and healthy
```

### **What to Look For:**
- ✅ **Immediate response** to SIGTERM signal
- ✅ **Gradual termination**: Pod stays `Running` briefly, then `Terminating`
- ✅ **Reasonable timing**: Shutdown completes within termination grace period (30s)
- ✅ **Clean replacement**: New pod becomes ready quickly

---

## 🔧 **Step 7: Test Graceful Degradation**

### **Command:**
```bash
# Test behavior when database becomes unavailable  
./scripts/test-degradation.sh
```

### **What This Tests:**
- **Circuit breaker activation**: Automatic failure detection
- **Fallback responses**: Serving cached/default data when DB is down
- **Feature flag behavior**: Graceful degradation of functionality
- **Recovery detection**: Circuit breaker reopening when service recovers

### **What to Expect:**
```bash
🔧 Testing graceful degradation...
✅ Initial state: All services healthy

💥 Simulating database failure...
📊 Scaling PostgreSQL to 0 replicas...

⏳ Waiting for circuit breaker activation...
🔍 Circuit breaker status: OPEN (failures detected)

📝 Testing degraded responses:
  GET /api/users → 200 (fallback data served)
  GET /health → 503 (dependency unavailable)
  GET /ready → 503 (not ready due to DB)

🔄 Restoring database service...
📊 Scaling PostgreSQL back to 1 replica...

⏳ Waiting for service recovery...
🔍 Circuit breaker status: CLOSED (service recovered)

✅ Full functionality restored
```

### **What to Look For:**
- ✅ **Circuit breaker opens** when database becomes unavailable
- ✅ **Fallback data served**: Application doesn't crash, provides default responses
- ✅ **Health checks reflect reality**: `/health` returns 503, `/ready` returns 503
- ✅ **Automatic recovery**: Circuit breaker closes when database returns
- ✅ **No manual intervention**: System self-heals

---

## 🌪️ **Step 8: Comprehensive Chaos Testing**

### **Command:**
```bash
# Run comprehensive resilience testing
./scripts/chaos-test.sh
```

### **What This Tests:**
- **Load testing**: High concurrent request volume
- **Circuit breaker thresholds**: Failure rate triggering
- **Resource pressure**: CPU and memory constraints
- **Network partitions**: Service communication failures
- **Recovery patterns**: System behavior after disruptions

### **What to Expect:**
```bash
🌪️  Comprehensive Chaos Testing...

📊 Load Testing (100 concurrent requests):
  ✅ Total requests: 1000
  ✅ Successful: 987 (98.7%)
  ✅ Failed: 13 (1.3%)
  ✅ Average response time: 45ms

🔥 Circuit Breaker Testing:
  📊 Initial state: CLOSED
  💥 Injecting failures...
  📊 Circuit breaker: OPEN (threshold reached)
  ⏳ Waiting for recovery...
  📊 Circuit breaker: CLOSED (service recovered)

🎯 Resource Pressure Testing:
  📊 CPU usage during load: 78% (within limits)
  📊 Memory usage: 95MB/128MB (within limits)
  ✅ No pods killed due to resource constraints

🔄 Recovery Validation:
  ✅ All pods healthy after chaos testing
  ✅ Services responsive to new requests
  ✅ Circuit breaker in optimal state
```

### **What to Look For:**
- ✅ **High success rate** under load (>95%)
- ✅ **Circuit breaker activation** at appropriate failure thresholds
- ✅ **Resource efficiency**: No OOMKilled pods
- ✅ **Complete recovery**: System returns to normal state
- ✅ **Performance metrics**: Response times remain reasonable

---

## 📊 **Step 9: Monitor and Observe**

### **Command:**
```bash
# Access application metrics and logs
kubectl port-forward -n resilient-demo svc/resilient-app 8080:8080 &

# View Prometheus metrics
curl http://localhost:8080/metrics

# Check application logs
kubectl logs -n resilient-demo -l app.kubernetes.io/name=resilient-app --tail=50
```

### **Key Metrics to Monitor:**
```prometheus
# Request metrics
http_requests_total{method="GET",path="/api/users",status="200"} 156
http_request_duration_seconds_bucket{method="GET",path="/api/users",le="0.1"} 142

# Circuit breaker metrics  
circuit_breaker_requests_total{name="database",state="success"} 234
circuit_breaker_requests_total{name="database",state="failure"} 12
circuit_breaker_state{name="database"} 0  # 0=closed, 1=open

# Resource metrics
go_memstats_heap_inuse_bytes 8.388608e+06
process_cpu_seconds_total 2.45
```

### **What to Look For:**
- ✅ **Request patterns**: HTTP status code distribution
- ✅ **Performance trends**: Response time percentiles
- ✅ **Circuit breaker health**: Success/failure ratios
- ✅ **Resource utilization**: Memory and CPU usage patterns
- ✅ **Error rates**: Low failure percentages

---

## 🧹 **Step 10: Cleanup**

### **Command:**
```bash
# Clean up all resources
kind delete cluster --name resilience-demo
```

### **What This Does:**
- **Removes Kind cluster** and all associated resources
- **Cleans up Docker containers** used by Kind
- **Frees system resources** (CPU, memory, disk)
- **Resets kubectl context** to previous setting

---

## 🎯 **Key Takeaways**

### **Resilience Patterns Demonstrated:**
1. **🛡️ Circuit Breaker**: Prevents cascade failures
2. **🔄 Graceful Shutdown**: Proper OS signal handling  
3. **📉 Graceful Degradation**: Fallback when dependencies fail
4. **🏥 Health Checks**: Comprehensive monitoring
5. **📊 Observability**: Metrics and structured logging
6. **⚖️ Resource Management**: Limits and requests
7. **🔧 Self-Healing**: Kubernetes native recovery

### **Production-Ready Features:**
- ✅ **Security**: Non-root containers, read-only filesystem
- ✅ **Scalability**: Horizontal pod autoscaling ready
- ✅ **Monitoring**: Prometheus metrics integration
- ✅ **Logging**: Structured JSON logging with correlation IDs
- ✅ **Configuration**: Environment-based configuration
- ✅ **Testing**: Comprehensive test automation

### **Beyond Basic Containerization:**
This demo shows that **true resilience requires more than just putting your app in a container**. It demands:
- **Application-level patterns** (circuit breakers, graceful shutdown)
- **Infrastructure patterns** (health checks, resource limits)  
- **Operational patterns** (monitoring, chaos testing)
- **Cultural patterns** (testing for failure, designing for degradation)

---

## 🚀 **Next Steps**

1. **Customize for your use case**: Adapt patterns to your specific requirements
2. **Add more chaos**: Implement additional failure scenarios  
3. **Production deployment**: Apply these patterns to real workloads
4. **Monitoring integration**: Connect to your observability stack
5. **Automation**: Integrate tests into CI/CD pipelines

**Remember**: Resilience is not a destination, it's a journey of continuous improvement! 🌟 