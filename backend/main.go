package main

import (
	"embed"
	"io/fs"
	"log"
	"net/http"
	"os"

	"github.com/go-chi/chi/v5"
	chimiddleware "github.com/go-chi/chi/v5/middleware"

	"github.com/SiamRahman29/cctracker/db"
	"github.com/SiamRahman29/cctracker/handlers"
	"github.com/SiamRahman29/cctracker/middleware"
)

//go:embed dashboard/index.html
var dashboardFS embed.FS

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	port := getEnv("PORT", "8080")
	dbPath := getEnv("DB_PATH", "./cctracker.db")

	database := db.Init(dbPath)
	defer database.Close()

	rl := middleware.NewRateLimiter()

	r := chi.NewRouter()
	r.Use(chimiddleware.Logger)
	r.Use(chimiddleware.Recoverer)
	r.Use(middleware.CORS())

	// Rate-limited write endpoint
	r.With(rl.Limit).Post("/api/sessions", handlers.CreateSession(database))

	// Other API routes
	r.Get("/api/sessions", handlers.ListSessions(database))
	r.Delete("/api/sessions/{id}", handlers.DeleteSession(database))
	r.Get("/api/stats", handlers.GetStats(database))
	r.Get("/api/stats/plugins", handlers.GetPluginStats(database))
	r.Get("/health", handlers.Health)

	// Embedded dashboard
	dashFS, err := fs.Sub(dashboardFS, "dashboard")
	if err != nil {
		log.Fatalf("failed to sub dashboard FS: %v", err)
	}
	r.Handle("/*", http.FileServer(http.FS(dashFS)))

	log.Printf("cctracker listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, r))
}
