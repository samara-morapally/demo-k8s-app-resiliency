package database

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strconv"
	"time"

	_ "github.com/lib/pq"
	"github.com/sony/gobreaker"
	"go.uber.org/zap"
)

type DB struct {
	conn          *sql.DB
	circuitBreaker *gobreaker.CircuitBreaker
	logger        *zap.Logger
}

type User struct {
	ID        int       `json:"id"`
	Name      string    `json:"name"`
	Email     string    `json:"email"`
	CreatedAt time.Time `json:"created_at"`
}

func NewConnection(ctx context.Context, logger *zap.Logger) (*DB, error) {
	// Get database configuration from environment
	dbHost := getEnvOrDefault("DB_HOST", "postgres")
	dbPort := getEnvOrDefault("DB_PORT", "5432")
	dbUser := getEnvOrDefault("DB_USER", "postgres")
	dbPassword := getEnvOrDefault("DB_PASSWORD", "postgres")
	dbName := getEnvOrDefault("DB_NAME", "resilient_db")

	// Build connection string
	connStr := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		dbHost, dbPort, dbUser, dbPassword, dbName)

	// Open database connection
	conn, err := sql.Open("postgres", connStr)
	if err != nil {
		return nil, fmt.Errorf("failed to open database connection: %w", err)
	}

	// Configure connection pool
	conn.SetMaxOpenConns(25)
	conn.SetMaxIdleConns(5)
	conn.SetConnMaxLifetime(5 * time.Minute)
	conn.SetConnMaxIdleTime(1 * time.Minute)

	// Test connection with timeout
	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	if err := conn.PingContext(pingCtx); err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to ping database: %w", err)
	}

	// Configure circuit breaker
	cbSettings := gobreaker.Settings{
		Name:        "database",
		MaxRequests: 3,
		Interval:    30 * time.Second, // Reset interval
		Timeout:     10 * time.Second, // Reduced timeout for quicker demo
		ReadyToTrip: func(counts gobreaker.Counts) bool {
			failureRatio := float64(counts.TotalFailures) / float64(counts.Requests)
			return counts.Requests >= 2 && failureRatio >= 0.5 // Trip faster
		},
		OnStateChange: func(name string, from gobreaker.State, to gobreaker.State) {
			logger.Info("Circuit breaker state changed",
				zap.String("name", name),
				zap.String("from", from.String()),
				zap.String("to", to.String()),
			)
		},
	}

	cb := gobreaker.NewCircuitBreaker(cbSettings)

	db := &DB{
		conn:           conn,
		circuitBreaker: cb,
		logger:         logger,
	}

	// Initialize database schema
	if err := db.initSchema(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to initialize database schema: %w", err)
	}

	logger.Info("Database connection established successfully")
	return db, nil
}

func (db *DB) Close() error {
	if db.conn != nil {
		return db.conn.Close()
	}
	return nil
}

func (db *DB) Ping(ctx context.Context) error {
	_, err := db.circuitBreaker.Execute(func() (interface{}, error) {
		return nil, db.conn.PingContext(ctx)
	})
	return err
}

func (db *DB) GetUsers(ctx context.Context) ([]User, error) {
	result, err := db.circuitBreaker.Execute(func() (interface{}, error) {
		query := `SELECT id, name, email, created_at FROM users ORDER BY created_at DESC LIMIT 100`
		
		rows, err := db.conn.QueryContext(ctx, query)
		if err != nil {
			return nil, err
		}
		defer rows.Close()

		var users []User
		for rows.Next() {
			var user User
			err := rows.Scan(&user.ID, &user.Name, &user.Email, &user.CreatedAt)
			if err != nil {
				return nil, err
			}
			users = append(users, user)
		}

		return users, rows.Err()
	})

	if err != nil {
		return nil, err
	}

	return result.([]User), nil
}

func (db *DB) GetUser(ctx context.Context, id int) (*User, error) {
	result, err := db.circuitBreaker.Execute(func() (interface{}, error) {
		query := `SELECT id, name, email, created_at FROM users WHERE id = $1`
		
		var user User
		err := db.conn.QueryRowContext(ctx, query, id).Scan(
			&user.ID, &user.Name, &user.Email, &user.CreatedAt)
		
		if err != nil {
			return nil, err
		}

		return &user, nil
	})

	if err != nil {
		return nil, err
	}

	return result.(*User), nil
}

func (db *DB) CreateUser(ctx context.Context, name, email string) (*User, error) {
	result, err := db.circuitBreaker.Execute(func() (interface{}, error) {
		query := `INSERT INTO users (name, email, created_at) VALUES ($1, $2, $3) RETURNING id, name, email, created_at`
		
		var user User
		err := db.conn.QueryRowContext(ctx, query, name, email, time.Now()).Scan(
			&user.ID, &user.Name, &user.Email, &user.CreatedAt)
		
		if err != nil {
			return nil, err
		}

		return &user, nil
	})

	if err != nil {
		return nil, err
	}

	return result.(*User), nil
}

func (db *DB) GetStats() gobreaker.Counts {
	return db.circuitBreaker.Counts()
}

func (db *DB) GetState() gobreaker.State {
	return db.circuitBreaker.State()
}

func (db *DB) initSchema(ctx context.Context) error {
	schema := `
		CREATE TABLE IF NOT EXISTS users (
			id SERIAL PRIMARY KEY,
			name VARCHAR(255) NOT NULL,
			email VARCHAR(255) UNIQUE NOT NULL,
			created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
		);

		-- Insert some sample data if table is empty
		INSERT INTO users (name, email) 
		SELECT 'John Doe', 'john@example.com'
		WHERE NOT EXISTS (SELECT 1 FROM users);
		
		INSERT INTO users (name, email) 
		SELECT 'Jane Smith', 'jane@example.com'
		WHERE NOT EXISTS (SELECT 1 FROM users WHERE email = 'jane@example.com');
	`

	_, err := db.conn.ExecContext(ctx, schema)
	return err
}

// SimulateFailure forces the circuit breaker to fail for testing
func (db *DB) SimulateFailure() {
	// Execute a few failing operations to trip the circuit breaker
	for i := 0; i < 5; i++ {
		db.circuitBreaker.Execute(func() (interface{}, error) {
			return nil, fmt.Errorf("simulated database failure")
		})
	}
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func getEnvOrDefaultInt(key string, defaultValue int) int {
	if value := os.Getenv(key); value != "" {
		if intValue, err := strconv.Atoi(value); err == nil {
			return intValue
		}
	}
	return defaultValue
} 