# Kubernetes Application Resilience Patterns

This document explains the resilience patterns implemented in the demo application and how they contribute to building truly resilient Kubernetes applications.

## Table of Contents

1. [Signal Handling and Graceful Shutdown](#signal-handling-and-graceful-shutdown)
2. [Circuit Breaker Pattern](#circuit-breaker-pattern)
3. [Graceful Degradation](#graceful-degradation)
4. [Health Checks and Probes](#health-checks-and-probes)
5. [Resource Management](#resource-management)
6. [Monitoring and Observability](#monitoring-and-observability)

## Signal Handling and Graceful Shutdown

### The Problem
When Kubernetes needs to terminate a pod (during deployments, scaling, or node maintenance), it sends a SIGTERM signal to the main process. Applications that don't handle this signal properly can:
- Lose in-flight requests
- Corrupt data
- Provide poor user experience

### Our Implementation

#### Signal Registration
```go
sigChan := make(chan os.Signal, 1)
signal.Notify(sigChan, 
    os.Interrupt,    // SIGINT (Ctrl+C)
    syscall.SIGTERM, // SIGTERM (Kubernetes graceful shutdown)
    syscall.SIGQUIT, // SIGQUIT
)
```

#### Graceful Shutdown Process
1. **Stop accepting new connections** - HTTP server stops listening
2. **Complete in-flight requests** - Wait for active requests to finish
3. **Close database connections** - Clean up resources
4. **Execute shutdown hooks** - Custom cleanup logic
5. **Exit gracefully** - Return proper exit code

#### Key Configuration
- `terminationGracePeriodSeconds: 60` - Gives the application time to shut down
- `preStop` hook with sleep - Allows load balancer to drain connections

### Testing
```bash
./scripts/test-graceful-shutdown.sh
```

## Circuit Breaker Pattern

### The Problem
When a dependency (like a database) fails, continued attempts to use it can:
- Waste resources
- Increase latency
- Cause cascade failures
- Make recovery harder

### Our Implementation

#### Circuit Breaker Configuration
```go
cbSettings := gobreaker.Settings{
    Name:        "database",
    MaxRequests: 3,
    Interval:    time.Minute,
    Timeout:     30 * time.Second,
    ReadyToTrip: func(counts gobreaker.Counts) bool {
        failureRatio := float64(counts.TotalFailures) / float64(counts.Requests)
        return counts.Requests >= 3 && failureRatio >= 0.6
    },
}
```

#### Circuit Breaker States
1. **Closed** - Normal operation, requests pass through
2. **Open** - Dependency is failing, requests fail fast
3. **Half-Open** - Testing if dependency has recovered

#### Usage Pattern
```go
result, err := db.circuitBreaker.Execute(func() (interface{}, error) {
    return db.conn.QueryContext(ctx, query)
})
```

### Testing
The circuit breaker can be tested by simulating database failures:
```bash
./scripts/test-degradation.sh
```

## Graceful Degradation

### The Problem
When dependencies fail, applications often fail completely, even when they could provide limited functionality.

### Our Implementation

#### Feature Flags
```go
func (h *Handler) isGracefulDegradationEnabled() bool {
    features := h.getEnabledFeatures()
    for _, feature := range features {
        if feature == "graceful_degradation" {
            return true
        }
    }
    return false
}
```

#### Fallback Strategies

1. **Read Operations** - Return cached/static data
```go
if h.isGracefulDegradationEnabled() {
    h.logger.Info("Database unavailable, returning fallback user data")
    fallbackUsers := h.getFallbackUsers()
    h.writeJSONResponse(w, http.StatusOK, fallbackUsers)
    return
}
```

2. **Write Operations** - Reject safely with proper error message
```go
if h.isGracefulDegradationEnabled() {
    h.writeErrorResponse(w, http.StatusServiceUnavailable, "degraded_mode", 
        "Service is in degraded mode, user creation temporarily unavailable")
    return
}
```

#### Configuration
```yaml
env:
- name: FEATURE_FLAGS
  value: "graceful_degradation,circuit_breaker,metrics"
```

### Testing
```bash
./scripts/test-degradation.sh
```

## Health Checks and Probes

### The Problem
Kubernetes needs to know:
- When the application is ready to receive traffic
- When the application is healthy and should continue running
- When the application has finished starting up

### Our Implementation

#### Three Types of Probes

1. **Startup Probe** - Is the application finished initializing?
```yaml
startupProbe:
  httpGet:
    path: /startup
    port: http
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 12  # 60 seconds total
```

2. **Readiness Probe** - Is the application ready to serve traffic?
```yaml
readinessProbe:
  httpGet:
    path: /ready
    port: http
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 3
```

3. **Liveness Probe** - Is the application healthy?
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 3
```

#### Health Check Logic

```go
func (c *Checker) ReadinessCheck(ctx context.Context) bool {
    // Check if startup is complete
    if !c.startup {
        return false
    }
    
    // Check database connectivity
    dbCheck := c.checkDatabase(ctx)
    if dbCheck.Status == StatusUnhealthy {
        // If graceful degradation is enabled, remain ready
        if c.isGracefulDegradationEnabled() {
            return true
        }
        return false
    }
    
    return true
}
```

#### Health Response Format
```json
{
  "status": "healthy",
  "timestamp": "2024-01-15T10:30:00Z",
  "uptime": "1h30m45s",
  "version": "1.0.0",
  "checks": {
    "database": {
      "name": "database",
      "status": "healthy",
      "message": "Database connection successful",
      "duration": "5ms"
    }
  }
}
```

### Testing
```bash
./scripts/test-health.sh
```

## Resource Management

### The Problem
Applications without proper resource limits can:
- Consume all available resources
- Cause node instability
- Impact other applications

### Our Implementation

#### Resource Limits and Requests
```yaml
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi
```

#### Pod Disruption Budget
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: resilient-app-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: resilient-app
```

#### Connection Pooling
```go
// Configure connection pool
conn.SetMaxOpenConns(25)
conn.SetMaxIdleConns(5)
conn.SetConnMaxLifetime(5 * time.Minute)
conn.SetConnMaxIdleTime(1 * time.Minute)
```

#### HTTP Server Timeouts
```go
server := &http.Server{
    Addr:              ":" + port,
    Handler:           router,
    ReadTimeout:       10 * time.Second,
    WriteTimeout:      10 * time.Second,
    IdleTimeout:       60 * time.Second,
    ReadHeaderTimeout: 5 * time.Second,
}
```

## Monitoring and Observability

### The Problem
Without proper monitoring, you can't:
- Detect issues early
- Understand system behavior
- Debug problems effectively
- Make informed decisions

### Our Implementation

#### Structured Logging
```go
logger.Info("HTTP request",
    zap.String("method", r.Method),
    zap.String("path", r.URL.Path),
    zap.Int("status", wrapper.statusCode),
    zap.Duration("duration", duration),
)
```

#### Prometheus Metrics
```go
var (
    httpRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"method", "endpoint", "status"},
    )
    
    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name: "http_request_duration_seconds",
            Help: "HTTP request duration in seconds",
        },
        []string{"method", "endpoint"},
    )
)
```

#### Health Monitoring
```go
func (c *Checker) backgroundHealthCheck() {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            response := c.HealthCheck(ctx)
            if response.Status != StatusHealthy {
                c.logger.Warn("Background health check detected issues")
            }
        }
    }
}
```

#### Circuit Breaker Monitoring
```go
OnStateChange: func(name string, from gobreaker.State, to gobreaker.State) {
    logger.Info("Circuit breaker state changed",
        zap.String("name", name),
        zap.String("from", from.String()),
        zap.String("to", to.String()),
    )
}
```

## Best Practices Summary

### 1. Signal Handling
- Always handle SIGTERM gracefully
- Set appropriate termination grace periods
- Use preStop hooks for load balancer draining
- Clean up resources properly

### 2. Circuit Breakers
- Implement circuit breakers for external dependencies
- Configure appropriate failure thresholds
- Monitor circuit breaker state changes
- Provide fallback mechanisms

### 3. Graceful Degradation
- Identify core vs. optional functionality
- Implement feature flags
- Provide meaningful error messages
- Fail safely, not completely

### 4. Health Checks
- Implement all three probe types appropriately
- Make health checks lightweight
- Return meaningful status information
- Consider dependencies in readiness checks

### 5. Resource Management
- Always set resource requests and limits
- Use pod disruption budgets
- Configure connection pooling
- Set appropriate timeouts

### 6. Monitoring
- Use structured logging
- Implement comprehensive metrics
- Monitor health continuously
- Track circuit breaker states

## Conclusion

Building truly resilient applications requires implementing multiple patterns working together:

1. **Graceful shutdown** ensures clean termination
2. **Circuit breakers** prevent cascade failures
3. **Graceful degradation** maintains partial functionality
4. **Proper health checks** enable Kubernetes to manage the application
5. **Resource management** ensures stability
6. **Monitoring** provides visibility

The demo application shows how these patterns work together to create a system that can handle various failure scenarios while maintaining availability and providing a good user experience. 