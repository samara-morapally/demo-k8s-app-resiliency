package shutdown

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/demo/resilient-app/internal/database"
	"go.uber.org/zap"
)

type Manager struct {
	logger     *zap.Logger
	server     *http.Server
	db         *database.DB
	shutdownFn []func(context.Context) error
	mu         sync.RWMutex
	isShutdown bool
}

func NewManager(logger *zap.Logger, server *http.Server, db *database.DB) *Manager {
	return &Manager{
		logger:     logger,
		server:     server,
		db:         db,
		shutdownFn: make([]func(context.Context) error, 0),
		isShutdown: false,
	}
}

// AddShutdownHook adds a function to be called during shutdown
func (m *Manager) AddShutdownHook(fn func(context.Context) error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.shutdownFn = append(m.shutdownFn, fn)
}

// Shutdown performs graceful shutdown of all components
func (m *Manager) Shutdown(ctx context.Context) error {
	m.mu.Lock()
	if m.isShutdown {
		m.mu.Unlock()
		return nil
	}
	m.isShutdown = true
	m.mu.Unlock()

	m.logger.Info("Initiating graceful shutdown")

	// Create a channel to track shutdown completion
	done := make(chan error, 1)
	
	go func() {
		defer close(done)
		
		// Step 1: Stop accepting new connections
		m.logger.Info("Stopping HTTP server...")
		if err := m.server.Shutdown(ctx); err != nil {
			m.logger.Error("HTTP server shutdown failed", zap.Error(err))
			done <- fmt.Errorf("HTTP server shutdown failed: %w", err)
			return
		}
		m.logger.Info("HTTP server stopped successfully")

		// Step 2: Execute custom shutdown hooks
		m.logger.Info("Executing shutdown hooks...")
		for i, fn := range m.shutdownFn {
			m.logger.Info("Executing shutdown hook", zap.Int("hook", i+1))
			if err := fn(ctx); err != nil {
				m.logger.Error("Shutdown hook failed", 
					zap.Int("hook", i+1), 
					zap.Error(err))
				done <- fmt.Errorf("shutdown hook %d failed: %w", i+1, err)
				return
			}
		}

		// Step 3: Close database connections
		m.logger.Info("Closing database connections...")
		if err := m.db.Close(); err != nil {
			m.logger.Error("Database close failed", zap.Error(err))
			done <- fmt.Errorf("database close failed: %w", err)
			return
		}
		m.logger.Info("Database connections closed successfully")

		// Step 4: Final cleanup
		m.logger.Info("Performing final cleanup...")
		time.Sleep(100 * time.Millisecond) // Brief pause for any remaining operations
		
		done <- nil
	}()

	// Wait for shutdown completion or timeout
	select {
	case err := <-done:
		if err != nil {
			return err
		}
		m.logger.Info("Graceful shutdown completed successfully")
		return nil
	case <-ctx.Done():
		m.logger.Warn("Shutdown timeout exceeded, forcing exit")
		return ctx.Err()
	}
}

// IsShutdown returns true if shutdown has been initiated
func (m *Manager) IsShutdown() bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.isShutdown
} 