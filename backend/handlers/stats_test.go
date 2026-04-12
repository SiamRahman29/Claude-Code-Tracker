package handlers

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/SiamRahman29/cctracker/db"
	"github.com/SiamRahman29/cctracker/models"
	"github.com/google/uuid"
)

func newTestDB(t *testing.T) *sql.DB {
	t.Helper()
	database := db.Init(":memory:")
	t.Cleanup(func() { database.Close() })
	return database
}

func seedSession(t *testing.T, database *sql.DB, s models.Session) {
	t.Helper()
	if s.ID == "" {
		s.ID = uuid.New().String()
	}
	if s.CreatedAt.IsZero() {
		s.CreatedAt = time.Now().UTC()
	}
	_, err := database.Exec(`
		INSERT INTO sessions (id,user_hash,task_type,plugins,duration_mins,outcome,rework_score,satisfaction,token_cost,model_used,country,created_at)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`,
		s.ID, s.UserHash, s.TaskType, s.Plugins, s.DurationMins, s.Outcome,
		s.ReworkScore, s.Satisfaction, s.TokenCost, s.ModelUsed, s.Country, s.CreatedAt,
	)
	if err != nil {
		t.Fatalf("seedSession: %v", err)
	}
}

func doGet(t *testing.T, handler http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}

// ---- GetStats ----

func TestGetStats_ZeroSessions(t *testing.T) {
	database := newTestDB(t)
	rec := doGet(t, GetStats(database), "/api/stats")

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var stats models.Stats
	if err := json.Unmarshal(rec.Body.Bytes(), &stats); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if stats.TotalSessions != 0 {
		t.Errorf("expected 0 sessions, got %d", stats.TotalSessions)
	}
	if stats.AvgSatisfaction != 0 {
		t.Errorf("expected 0 avg_satisfaction, got %f", stats.AvgSatisfaction)
	}
	if stats.CompletionRate != 0 {
		t.Errorf("expected 0 completion_rate, got %f", stats.CompletionRate)
	}
}

func TestGetStats_KnownSessions(t *testing.T) {
	database := newTestDB(t)
	base := models.Session{
		UserHash: "abc123def456", TaskType: "feature", Plugins: "none",
		DurationMins: 30, Outcome: "complete", ReworkScore: 1,
		Satisfaction: 4, TokenCost: 0.5, ModelUsed: "test",
	}
	seedSession(t, database, base)
	base.ID = uuid.New().String()
	base.Outcome = "partial"
	base.Satisfaction = 2
	seedSession(t, database, base)

	rec := doGet(t, GetStats(database), "/api/stats")
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var stats models.Stats
	if err := json.Unmarshal(rec.Body.Bytes(), &stats); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if stats.TotalSessions != 2 {
		t.Errorf("expected 2 sessions, got %d", stats.TotalSessions)
	}
	// avg satisfaction = (4+2)/2 = 3.0
	if stats.AvgSatisfaction != 3.0 {
		t.Errorf("expected avg_satisfaction=3.0, got %f", stats.AvgSatisfaction)
	}
	// completion_rate: 1 complete out of 2 = 0.5
	if stats.CompletionRate != 0.5 {
		t.Errorf("expected completion_rate=0.5, got %f", stats.CompletionRate)
	}
}

func TestGetStats_ReworkDistribution(t *testing.T) {
	database := newTestDB(t)
	scores := []int{0, 1, 2, 3}
	for _, score := range scores {
		seedSession(t, database, models.Session{
			UserHash: "abc123def456", TaskType: "feature", Plugins: "none",
			DurationMins: 10, Outcome: "complete", ReworkScore: score,
			Satisfaction: 3, TokenCost: 0, ModelUsed: "test",
		})
	}

	rec := doGet(t, GetStats(database), "/api/stats")
	var stats models.Stats
	json.Unmarshal(rec.Body.Bytes(), &stats)

	expectedNames := map[string]int{"none": 1, "minor": 1, "moderate": 1, "heavy": 1}
	for name, expectedCount := range expectedNames {
		if stats.ReworkDistribution[name] != expectedCount {
			t.Errorf("rework_distribution[%q]: expected %d, got %d", name, expectedCount, stats.ReworkDistribution[name])
		}
	}
}

func TestGetStats_TaskTypeDistribution(t *testing.T) {
	database := newTestDB(t)
	for _, tt := range []string{"feature", "feature", "bug"} {
		seedSession(t, database, models.Session{
			UserHash: "abc123def456", TaskType: tt, Plugins: "none",
			DurationMins: 10, Outcome: "complete", ReworkScore: 0,
			Satisfaction: 3, TokenCost: 0, ModelUsed: "test",
		})
	}

	rec := doGet(t, GetStats(database), "/api/stats")
	var stats models.Stats
	json.Unmarshal(rec.Body.Bytes(), &stats)

	if stats.TaskTypeDistribution["feature"] != 2 {
		t.Errorf("expected feature=2, got %d", stats.TaskTypeDistribution["feature"])
	}
	if stats.TaskTypeDistribution["bug"] != 1 {
		t.Errorf("expected bug=1, got %d", stats.TaskTypeDistribution["bug"])
	}
}

// ---- GetPluginStats ----

func TestGetPluginStats_ZeroSessions(t *testing.T) {
	database := newTestDB(t)
	rec := doGet(t, GetPluginStats(database), "/api/stats/plugins")

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var result []models.PluginStat
	if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("expected empty result, got %d rows", len(result))
	}
}

func TestGetPluginStats_TwoGroups(t *testing.T) {
	database := newTestDB(t)
	seedSession(t, database, models.Session{
		UserHash: "abc123def456", TaskType: "feature", Plugins: "none",
		DurationMins: 10, Outcome: "complete", ReworkScore: 1,
		Satisfaction: 3, TokenCost: 0, ModelUsed: "test",
	})
	seedSession(t, database, models.Session{
		UserHash: "abc123def456", TaskType: "feature", Plugins: "gstack",
		DurationMins: 10, Outcome: "complete", ReworkScore: 0,
		Satisfaction: 5, TokenCost: 0, ModelUsed: "test",
	})

	rec := doGet(t, GetPluginStats(database), "/api/stats/plugins")
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var result []models.PluginStat
	json.Unmarshal(rec.Body.Bytes(), &result)

	if len(result) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(result))
	}
	// Results are ordered by avg_satisfaction DESC so gstack (5.0) comes first
	if result[0].Plugins != "gstack" {
		t.Errorf("expected gstack first (higher satisfaction), got %q", result[0].Plugins)
	}
	if result[0].AvgReworkScore != 0 {
		t.Errorf("gstack avg_rework: expected 0, got %f", result[0].AvgReworkScore)
	}
	if result[1].Plugins != "none" {
		t.Errorf("expected none second, got %q", result[1].Plugins)
	}
	if result[1].AvgReworkScore != 1.0 {
		t.Errorf("none avg_rework: expected 1.0, got %f", result[1].AvgReworkScore)
	}
}
