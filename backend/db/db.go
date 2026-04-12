package db

import (
	"database/sql"
	"log"

	_ "modernc.org/sqlite"
)

func Init(path string) *sql.DB {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		log.Fatalf("failed to open db: %v", err)
	}

	// SQLite supports one writer at a time; serialize writes through a single connection
	db.SetMaxOpenConns(1)

	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		log.Fatalf("failed to set WAL mode: %v", err)
	}

	schema := `
CREATE TABLE IF NOT EXISTS sessions (
    id            TEXT PRIMARY KEY,
    user_hash     TEXT NOT NULL,
    task_type     TEXT NOT NULL DEFAULT 'other',
    plugins       TEXT NOT NULL DEFAULT 'none',
    duration_mins INTEGER NOT NULL DEFAULT 0,
    outcome       TEXT NOT NULL DEFAULT 'complete',
    rework_score  INTEGER NOT NULL DEFAULT 0,
    satisfaction  INTEGER NOT NULL DEFAULT 3,
    token_cost    REAL NOT NULL DEFAULT 0,
    model_used    TEXT NOT NULL DEFAULT '',
    country       TEXT NOT NULL DEFAULT 'unknown',
    created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_hash ON sessions(user_hash);
CREATE INDEX IF NOT EXISTS idx_created_at ON sessions(created_at);
CREATE INDEX IF NOT EXISTS idx_plugins ON sessions(plugins);
`
	if _, err := db.Exec(schema); err != nil {
		log.Fatalf("failed to create schema: %v", err)
	}

	return db
}
