# 🚀 Quick Reference Guide - Kubernetes Resilience Demo

## 📋 **Essential Commands**

```bash
# 1. Setup
git clone https://github.com/samara-morapally/demo-k8s-app-resiliency
cd demo-k8s-app-resiliency
./scripts/setup-cluster.sh

# 2. Build & Load Application
./scripts/build-and-load.sh

# 3. Deploy Complete Stack
./scripts/deploy.sh

# 4. Test Resilience
./scripts/test-health.sh
./scripts/test-graceful-shutdown.sh
./scripts/test-degradation.sh
./scripts/chaos-test.sh

# 5. Manual Testing
kubectl delete pod -n resilient-demo -l app.kubernetes.io/name=resilient-app
kubectl get pods -n resilient-demo -w

# 6. Monitor
kubectl port-forward -n resilient-demo svc/resilient-app 8080:8080
curl http://localhost:8080/health
curl http://localhost:8080/metrics

# 7. Cleanup
kind delete cluster --name resilience-demo
```

## 🎯 **Expected Success Indicators**

### **Healthy System:**
```bash
# All pods running
NAME                            READY   STATUS    RESTARTS   AGE
postgres-b8b766499-6jhxw        1/1     Running   0          2m
resilient-app-b886bbbfc-mqdd8   1/1     Running   0          1m
resilient-app-b886bbbfc-rmjvm   1/1     Running   0          1m
resilient-app-b886bbbfc-tk6jk   1/1     Running   0          1m

# Health check response
{
  "status": "healthy",
  "checks": {
    "database": {"status": "healthy"},
    "memory": {"status": "healthy"},
    "features": {"status": "healthy"}
  }
}

# Circuit breaker metrics
circuit_breaker_state{name="database"} 0  # 0=closed (healthy)
```

### **Resilience Validation:**
- ✅ **Pod deletion**: New pod created within 30 seconds
- ✅ **Graceful shutdown**: SIGTERM handled, 15-30 second termination
- ✅ **Circuit breaker**: Opens on failures, closes on recovery
- ✅ **Load testing**: >95% success rate under stress
- ✅ **Resource limits**: No OOMKilled pods

## 🔧 **Troubleshooting**

### **Common Issues:**
```bash
# Docker not running
sudo launchctl stop com.docker.vmnetd
sudo launchctl start com.docker.vmnetd

# Pods stuck in CrashLoopBackOff
kubectl rollout restart deployment/resilient-app -n resilient-demo

# Port forwarding conflicts
pkill -f "kubectl.*port-forward" || true

# Check cluster health
kubectl get nodes
kubectl get pods -n resilient-demo

# Rebuild application if needed
./scripts/build-and-load.sh
```

### **Key Files:**
- `resilient-app/` - Go application source
  - `main.go` - Application entry point with graceful shutdown
  - `internal/database/` - Circuit breaker implementation
  - `internal/handlers/` - HTTP handlers with graceful degradation
  - `internal/health/` - Health check implementations
- `k8s/` - Kubernetes manifests
  - `deployment.yaml` - App deployment with probes and resource limits
  - `postgres.yaml` - Database deployment
  - `service.yaml` - Service definitions
- `scripts/` - Automation scripts
  - `setup-cluster.sh` - Creates Kind cluster
  - `build-and-load.sh` - Builds and loads Docker image
  - `deploy.sh` - Deploys complete stack
  - `test-*.sh` - Various resilience tests

## 📊 **Architecture Overview**

```
┌─────────────────┐    ┌─────────────────┐
│   Load Balancer │    │   Kubernetes    │
│   (Service)     │────│   3 App Pods    │
└─────────────────┘    └─────────────────┘
         │                       │
         │              ┌─────────────────┐
         │              │   PostgreSQL    │
         └──────────────│      Pod        │
                        └─────────────────┘

Resilience Features:
├── Circuit Breaker (Sony Gobreaker)
├── Health Checks (Startup/Ready/Live)
├── Graceful Shutdown (SIGTERM handling)
├── Resource Limits (CPU/Memory)
├── Pod Disruption Budget
├── Prometheus Metrics
└── Structured Logging (Zap)
```

## 🚀 **Workflow Summary**

### **Setup Phase:**
1. `./scripts/setup-cluster.sh` - Creates 3-node Kind cluster
2. `./scripts/build-and-load.sh` - Builds Go app, creates Docker image, loads into Kind
3. `./scripts/deploy.sh` - Deploys PostgreSQL + App + Services

### **Testing Phase:**
4. `./scripts/test-health.sh` - Validates all endpoints and functionality
5. `./scripts/test-graceful-shutdown.sh` - Tests SIGTERM handling
6. `./scripts/test-degradation.sh` - Tests circuit breaker and fallbacks
7. `./scripts/chaos-test.sh` - Comprehensive load and chaos testing

### **Manual Testing:**
- Pod deletion: `kubectl delete pod -n resilient-demo -l app.kubernetes.io/name=resilient-app`
- Watch recovery: `kubectl get pods -n resilient-demo -w`
- Port forward: `kubectl port-forward -n resilient-demo svc/resilient-app 8080:8080`

### **Cleanup:**
- `kind delete cluster --name resilience-demo`

## 💡 **Key Success Metrics**

- **98.7% success rate** under load testing
- **Sub-30 second recovery** from pod failures  
- **Zero data loss** during graceful shutdowns
- **Automatic circuit breaker** activation/recovery
- **Comprehensive observability** with metrics and logs

## 🔗 **Repository**

**GitHub**: https://github.com/samara-morapally/demo-k8s-app-resiliency

**Quick Start:**
```bash
git clone https://github.com/samara-morapally/demo-k8s-app-resiliency
cd demo-k8s-app-resiliency
./scripts/setup-cluster.sh && ./scripts/build-and-load.sh && ./scripts/deploy.sh
``` 