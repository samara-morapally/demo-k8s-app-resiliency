package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/demo/resilient-app/internal/database"
	"github.com/demo/resilient-app/internal/health"
	"github.com/gorilla/mux"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"go.uber.org/zap"
)

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

type Handler struct {
	logger        *zap.Logger
	db            *database.DB
	healthChecker *health.Checker
}

type ErrorResponse struct {
	Error   string `json:"error"`
	Code    string `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

type CreateUserRequest struct {
	Name  string `json:"name"`
	Email string `json:"email"`
}

func NewHandler(logger *zap.Logger, db *database.DB, healthChecker *health.Checker) *Handler {
	return &Handler{
		logger:        logger,
		db:            db,
		healthChecker: healthChecker,
	}
}

// Health check endpoint for liveness probe
func (h *Handler) HealthCheck(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	response := h.healthChecker.HealthCheck(ctx)
	
	statusCode := http.StatusOK
	if response.Status == health.StatusUnhealthy {
		statusCode = http.StatusServiceUnavailable
	} else if response.Status == health.StatusDegraded {
		statusCode = http.StatusOK // Still healthy enough for liveness
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	json.NewEncoder(w).Encode(response)
}

// Readiness check endpoint for readiness probe
func (h *Handler) ReadinessCheck(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	ready := h.healthChecker.ReadinessCheck(ctx)
	
	if ready {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	} else {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte("Not Ready"))
	}
}

// Startup check endpoint for startup probe
func (h *Handler) StartupCheck(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	started := h.healthChecker.StartupCheck(ctx)
	
	if started {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("Started"))
	} else {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte("Starting"))
	}
}

// Get all users with graceful degradation
func (h *Handler) GetUsers(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	users, err := h.db.GetUsers(ctx)
	if err != nil {
		h.logger.Error("Failed to get users", zap.Error(err))
		
		// Graceful degradation: return cached or minimal data
		if h.isGracefulDegradationEnabled() {
			h.logger.Info("Database unavailable, returning fallback user data")
			fallbackUsers := h.getFallbackUsers()
			h.writeJSONResponse(w, http.StatusOK, fallbackUsers)
			return
		}
		
		h.writeErrorResponse(w, http.StatusInternalServerError, "database_error", 
			"Unable to retrieve users")
		return
	}

	h.writeJSONResponse(w, http.StatusOK, users)
}

// Get single user by ID
func (h *Handler) GetUser(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	idStr := vars["id"]
	
	id, err := strconv.Atoi(idStr)
	if err != nil {
		h.writeErrorResponse(w, http.StatusBadRequest, "invalid_id", 
			"User ID must be a valid number")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	user, err := h.db.GetUser(ctx, id)
	if err != nil {
		h.logger.Error("Failed to get user", zap.Int("id", id), zap.Error(err))
		
		// Graceful degradation
		if h.isGracefulDegradationEnabled() {
			fallbackUser := h.getFallbackUser(id)
			if fallbackUser != nil {
				h.logger.Info("Database unavailable, returning fallback user data", 
					zap.Int("id", id))
				h.writeJSONResponse(w, http.StatusOK, fallbackUser)
				return
			}
		}
		
		h.writeErrorResponse(w, http.StatusNotFound, "user_not_found", 
			"User not found")
		return
	}

	h.writeJSONResponse(w, http.StatusOK, user)
}

// Create new user
func (h *Handler) CreateUser(w http.ResponseWriter, r *http.Request) {
	var req CreateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeErrorResponse(w, http.StatusBadRequest, "invalid_json", 
			"Invalid JSON in request body")
		return
	}

	// Validate input
	if req.Name == "" || req.Email == "" {
		h.writeErrorResponse(w, http.StatusBadRequest, "missing_fields", 
			"Name and email are required")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	user, err := h.db.CreateUser(ctx, req.Name, req.Email)
	if err != nil {
		h.logger.Error("Failed to create user", 
			zap.String("name", req.Name), 
			zap.String("email", req.Email), 
			zap.Error(err))
		
		// In degraded mode, we might not be able to create users
		if h.isGracefulDegradationEnabled() {
			h.writeErrorResponse(w, http.StatusServiceUnavailable, "degraded_mode", 
				"Service is in degraded mode, user creation temporarily unavailable")
			return
		}
		
		h.writeErrorResponse(w, http.StatusInternalServerError, "creation_failed", 
			"Failed to create user")
		return
	}

	h.writeJSONResponse(w, http.StatusCreated, user)
}

// Get system status including circuit breaker state
func (h *Handler) GetSystemStatus(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	healthResponse := h.healthChecker.HealthCheck(ctx)
	circuitBreakerStats := h.db.GetStats()
	circuitBreakerState := h.db.GetState()
	
	status := map[string]interface{}{
		"health":          healthResponse,
		"circuit_breaker": map[string]interface{}{
			"state":           circuitBreakerState.String(),
			"requests":        circuitBreakerStats.Requests,
			"total_successes": circuitBreakerStats.TotalSuccesses,
			"total_failures":  circuitBreakerStats.TotalFailures,
		},
		"features": h.getEnabledFeatures(),
	}

	h.writeJSONResponse(w, http.StatusOK, status)
}

// Middleware for logging requests
func (h *Handler) LoggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		
		// Create a response writer wrapper to capture status code
		wrapper := &responseWriterWrapper{ResponseWriter: w, statusCode: http.StatusOK}
		
		next.ServeHTTP(wrapper, r)
		
		duration := time.Since(start)
		
		h.logger.Info("HTTP request",
			zap.String("method", r.Method),
			zap.String("path", r.URL.Path),
			zap.String("remote_addr", r.RemoteAddr),
			zap.Int("status", wrapper.statusCode),
			zap.Duration("duration", duration),
		)
	})
}

// Middleware for metrics collection
func (h *Handler) MetricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		wrapper := &responseWriterWrapper{ResponseWriter: w, statusCode: http.StatusOK}
		
		next.ServeHTTP(wrapper, r)
		
		duration := time.Since(start).Seconds()
		endpoint := h.getEndpointLabel(r.URL.Path)
		
		httpRequestsTotal.WithLabelValues(r.Method, endpoint, 
			strconv.Itoa(wrapper.statusCode)).Inc()
		httpRequestDuration.WithLabelValues(r.Method, endpoint).Observe(duration)
	})
}

// Middleware for panic recovery
func (h *Handler) RecoveryMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if err := recover(); err != nil {
				h.logger.Error("Panic recovered",
					zap.Any("error", err),
					zap.String("path", r.URL.Path),
					zap.String("method", r.Method),
				)
				
				h.writeErrorResponse(w, http.StatusInternalServerError, "internal_error", 
					"Internal server error")
			}
		}()
		
		next.ServeHTTP(w, r)
	})
}

// Helper functions

func (h *Handler) writeJSONResponse(w http.ResponseWriter, statusCode int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		h.logger.Error("Failed to encode JSON response", zap.Error(err))
	}
}

func (h *Handler) writeErrorResponse(w http.ResponseWriter, statusCode int, code, message string) {
	response := ErrorResponse{
		Error:   http.StatusText(statusCode),
		Code:    code,
		Message: message,
	}
	h.writeJSONResponse(w, statusCode, response)
}

func (h *Handler) isGracefulDegradationEnabled() bool {
	features := h.getEnabledFeatures()
	for _, feature := range features {
		if feature == "graceful_degradation" {
			return true
		}
	}
	return false
}

func (h *Handler) getEnabledFeatures() []string {
	// This would typically come from a feature flag service
	// For demo purposes, we'll use environment variables
	features := []string{"graceful_degradation", "circuit_breaker", "metrics"}
	return features
}

func (h *Handler) getFallbackUsers() []database.User {
	// Return cached or static fallback data
	return []database.User{
		{
			ID:        1,
			Name:      "Fallback User",
			Email:     "fallback@example.com",
			CreatedAt: time.Now().Add(-24 * time.Hour),
		},
	}
}

func (h *Handler) getFallbackUser(id int) *database.User {
	// Return cached or static fallback data for specific user
	if id == 1 {
		return &database.User{
			ID:        1,
			Name:      "Fallback User",
			Email:     "fallback@example.com",
			CreatedAt: time.Now().Add(-24 * time.Hour),
		}
	}
	return nil
}

func (h *Handler) getEndpointLabel(path string) string {
	// Normalize paths for metrics
	if strings.HasPrefix(path, "/api/users/") {
		return "/api/users/{id}"
	}
	return path
}

// Response writer wrapper to capture status code
type responseWriterWrapper struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriterWrapper) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
} 