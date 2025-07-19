package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/demo/resilient-app/internal/database"
	"github.com/demo/resilient-app/internal/handlers"
	"github.com/demo/resilient-app/internal/health"
	"github.com/demo/resilient-app/internal/shutdown"
	"github.com/gorilla/mux"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.uber.org/zap"
)

const (
	defaultPort                = "8080"
	defaultShutdownTimeout     = 30 * time.Second
	defaultReadTimeout         = 10 * time.Second
	defaultWriteTimeout        = 10 * time.Second
	defaultIdleTimeout         = 60 * time.Second
	defaultReadHeaderTimeout   = 5 * time.Second
)

func main() {
	// Initialize structured logging
	logger, err := zap.NewProduction()
	if err != nil {
		fmt.Printf("Failed to initialize logger: %v\n", err)
		os.Exit(1)
	}
	defer logger.Sync()

	// Create application context
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	logger.Info("Starting resilient application", 
		zap.String("version", "1.0.0"),
		zap.String("port", getEnvOrDefault("PORT", defaultPort)),
	)

	// Initialize database connection with circuit breaker
	db, err := database.NewConnection(ctx, logger)
	if err != nil {
		logger.Fatal("Failed to initialize database connection", zap.Error(err))
	}
	defer db.Close()

	// Initialize health checker
	healthChecker := health.NewChecker(logger, db)

	// Initialize handlers
	handler := handlers.NewHandler(logger, db, healthChecker)

	// Setup HTTP router
	router := setupRouter(handler)

	// Configure HTTP server with proper timeouts
	server := &http.Server{
		Addr:              ":" + getEnvOrDefault("PORT", defaultPort),
		Handler:           router,
		ReadTimeout:       defaultReadTimeout,
		WriteTimeout:      defaultWriteTimeout,
		IdleTimeout:       defaultIdleTimeout,
		ReadHeaderTimeout: defaultReadHeaderTimeout,
	}

	// Setup graceful shutdown
	shutdownManager := shutdown.NewManager(logger, server, db)

	// Start server in goroutine
	go func() {
		logger.Info("Server starting", zap.String("addr", server.Addr))
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatal("Server failed to start", zap.Error(err))
		}
	}()

	// Wait for interrupt signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, 
		os.Interrupt,    // SIGINT (Ctrl+C)
		syscall.SIGTERM, // SIGTERM (Kubernetes graceful shutdown)
		syscall.SIGQUIT, // SIGQUIT
	)

	// Block until signal received
	sig := <-sigChan
	logger.Info("Received shutdown signal", 
		zap.String("signal", sig.String()),
		zap.Duration("timeout", defaultShutdownTimeout),
	)

	// Initiate graceful shutdown
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), defaultShutdownTimeout)
	defer shutdownCancel()

	if err := shutdownManager.Shutdown(shutdownCtx); err != nil {
		logger.Error("Graceful shutdown failed", zap.Error(err))
		os.Exit(1)
	}

	logger.Info("Application shutdown completed successfully")
}

func setupRouter(handler *handlers.Handler) *mux.Router {
	router := mux.NewRouter()

	// Health check endpoints (used by Kubernetes probes)
	router.HandleFunc("/health", handler.HealthCheck).Methods("GET")
	router.HandleFunc("/ready", handler.ReadinessCheck).Methods("GET")
	router.HandleFunc("/startup", handler.StartupCheck).Methods("GET")

	// API endpoints
	api := router.PathPrefix("/api").Subrouter()
	api.HandleFunc("/users", handler.GetUsers).Methods("GET")
	api.HandleFunc("/users", handler.CreateUser).Methods("POST")
	api.HandleFunc("/users/{id}", handler.GetUser).Methods("GET")
	api.HandleFunc("/status", handler.GetSystemStatus).Methods("GET")

	// Metrics endpoint for Prometheus
	router.Handle("/metrics", promhttp.Handler())

	// Add middleware
	router.Use(handler.LoggingMiddleware)
	router.Use(handler.MetricsMiddleware)
	router.Use(handler.RecoveryMiddleware)

	return router
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
} 