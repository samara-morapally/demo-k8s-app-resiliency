package health

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/demo/resilient-app/internal/database"
	"go.uber.org/zap"
)

type Status string

const (
	StatusHealthy   Status = "healthy"
	StatusUnhealthy Status = "unhealthy"
	StatusDegraded  Status = "degraded"
)

type Check struct {
	Name      string        `json:"name"`
	Status    Status        `json:"status"`
	Message   string        `json:"message,omitempty"`
	Duration  time.Duration `json:"duration"`
	Timestamp time.Time     `json:"timestamp"`
}

type HealthResponse struct {
	Status    Status            `json:"status"`
	Timestamp time.Time         `json:"timestamp"`
	Uptime    time.Duration     `json:"uptime"`
	Version   string            `json:"version"`
	Checks    map[string]*Check `json:"checks"`
}

type Checker struct {
	logger    *zap.Logger
	db        *database.DB
	startTime time.Time
	mu        sync.RWMutex
	ready     bool
	startup   bool
}

func NewChecker(logger *zap.Logger, db *database.DB) *Checker {
	checker := &Checker{
		logger:    logger,
		db:        db,
		startTime: time.Now(),
		ready:     false,
		startup:   false,
	}

	// Start background health monitoring
	go checker.backgroundHealthCheck()
	
	// Mark as started up after a brief delay (simulating app initialization)
	go func() {
		time.Sleep(5 * time.Second)
		checker.mu.Lock()
		checker.startup = true
		checker.mu.Unlock()
		logger.Info("Application startup completed")
	}()

	return checker
}

func (c *Checker) HealthCheck(ctx context.Context) *HealthResponse {
	c.mu.RLock()
	defer c.mu.RUnlock()

	response := &HealthResponse{
		Status:    StatusHealthy,
		Timestamp: time.Now(),
		Uptime:    time.Since(c.startTime),
		Version:   getEnvOrDefault("APP_VERSION", "1.0.0"),
		Checks:    make(map[string]*Check),
	}

	// Database health check
	dbCheck := c.checkDatabase(ctx)
	response.Checks["database"] = dbCheck

	// Memory health check
	memCheck := c.checkMemory()
	response.Checks["memory"] = memCheck

	// Feature flags check
	featuresCheck := c.checkFeatures()
	response.Checks["features"] = featuresCheck

	// Determine overall status
	response.Status = c.determineOverallStatus(response.Checks)

	return response
}

func (c *Checker) ReadinessCheck(ctx context.Context) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()

	// Check if startup is complete
	if !c.startup {
		return false
	}

	// Check database connectivity
	dbCheck := c.checkDatabase(ctx)
	if dbCheck.Status == StatusUnhealthy {
		// If database is down, we can still serve in degraded mode
		// but we need to check if graceful degradation is enabled
		if c.isGracefulDegradationEnabled() {
			c.logger.Info("Database unhealthy, but graceful degradation enabled - remaining ready")
			return true
		}
		return false
	}

	c.ready = true
	return true
}

func (c *Checker) StartupCheck(ctx context.Context) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.startup
}

func (c *Checker) IsReady() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.ready
}

func (c *Checker) checkDatabase(ctx context.Context) *Check {
	start := time.Now()
	check := &Check{
		Name:      "database",
		Timestamp: start,
	}

	// Create a timeout context for the database check
	dbCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	err := c.db.Ping(dbCtx)
	check.Duration = time.Since(start)

	if err != nil {
		check.Status = StatusUnhealthy
		check.Message = fmt.Sprintf("Database connection failed: %v", err)
		c.logger.Warn("Database health check failed", zap.Error(err))
	} else {
		check.Status = StatusHealthy
		check.Message = "Database connection successful"
	}

	return check
}

func (c *Checker) checkMemory() *Check {
	start := time.Now()
	check := &Check{
		Name:      "memory",
		Timestamp: start,
		Status:    StatusHealthy,
		Message:   "Memory usage within normal limits",
		Duration:  time.Since(start),
	}

	// In a real application, you might check actual memory usage
	// For demo purposes, we'll simulate this
	return check
}

func (c *Checker) checkFeatures() *Check {
	start := time.Now()
	check := &Check{
		Name:      "features",
		Timestamp: start,
		Status:    StatusHealthy,
		Duration:  time.Since(start),
	}

	features := c.getEnabledFeatures()
	if len(features) == 0 {
		check.Status = StatusDegraded
		check.Message = "No features enabled - running in minimal mode"
	} else {
		check.Message = fmt.Sprintf("Features enabled: %s", strings.Join(features, ", "))
	}

	return check
}

func (c *Checker) determineOverallStatus(checks map[string]*Check) Status {
	hasUnhealthy := false
	hasDegraded := false

	for _, check := range checks {
		switch check.Status {
		case StatusUnhealthy:
			hasUnhealthy = true
		case StatusDegraded:
			hasDegraded = true
		}
	}

	if hasUnhealthy && !c.isGracefulDegradationEnabled() {
		return StatusUnhealthy
	}
	if hasUnhealthy || hasDegraded {
		return StatusDegraded
	}
	return StatusHealthy
}

func (c *Checker) backgroundHealthCheck() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			response := c.HealthCheck(ctx)
			
			if response.Status != StatusHealthy {
				c.logger.Warn("Background health check detected issues",
					zap.String("status", string(response.Status)),
					zap.Int("failed_checks", c.countFailedChecks(response.Checks)),
				)
			}
			
			cancel()
		}
	}
}

func (c *Checker) countFailedChecks(checks map[string]*Check) int {
	count := 0
	for _, check := range checks {
		if check.Status != StatusHealthy {
			count++
		}
	}
	return count
}

func (c *Checker) isGracefulDegradationEnabled() bool {
	features := c.getEnabledFeatures()
	for _, feature := range features {
		if feature == "graceful_degradation" {
			return true
		}
	}
	return false
}

func (c *Checker) getEnabledFeatures() []string {
	featureFlags := getEnvOrDefault("FEATURE_FLAGS", "graceful_degradation,circuit_breaker")
	if featureFlags == "" {
		return []string{}
	}
	
	features := strings.Split(featureFlags, ",")
	for i, feature := range features {
		features[i] = strings.TrimSpace(feature)
	}
	
	return features
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
} 