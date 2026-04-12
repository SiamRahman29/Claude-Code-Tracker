package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/go-chi/chi/v5"

	"github.com/SiamRahman29/cctracker/models"
)

func TestCreateSession_Valid(t *testing.T) {
	database := newTestDB(t)
	body := `{"user_hash":"abc123def456","task_type":"feature","plugins":"none","duration_mins":30,"outcome":"complete","rework_score":1,"satisfaction":4,"token_cost":0.5,"model_used":"claude-opus-4"}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	CreateSession(database).ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var s models.Session
	if err := json.Unmarshal(rec.Body.Bytes(), &s); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if s.ID == "" {
		t.Error("expected non-empty ID")
	}
	if s.UserHash != "abc123def456" {
		t.Errorf("unexpected user_hash: %q", s.UserHash)
	}
}

func TestCreateSession_InvalidTaskType(t *testing.T) {
	database := newTestDB(t)
	body := `{"user_hash":"abc123def456","task_type":"invalid","plugins":"none","duration_mins":10,"outcome":"complete","rework_score":0,"satisfaction":3,"token_cost":0,"model_used":""}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	CreateSession(database).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", rec.Code)
	}
}

func TestCreateSession_UserHashTooShort(t *testing.T) {
	database := newTestDB(t)
	body := `{"user_hash":"short","task_type":"feature","plugins":"none","duration_mins":10,"outcome":"complete","rework_score":0,"satisfaction":3,"token_cost":0,"model_used":""}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	CreateSession(database).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", rec.Code)
	}
}

func TestCreateSession_UserHashTooLong(t *testing.T) {
	database := newTestDB(t)
	body := `{"user_hash":"abcdefghijklmnopq","task_type":"feature","plugins":"none","duration_mins":10,"outcome":"complete","rework_score":0,"satisfaction":3,"token_cost":0,"model_used":""}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	CreateSession(database).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for user_hash >16 chars, got %d", rec.Code)
	}
}

func TestCreateSession_UserHashBoundaryMin(t *testing.T) {
	database := newTestDB(t)
	body := `{"user_hash":"12345678","task_type":"feature","plugins":"none","duration_mins":10,"outcome":"complete","rework_score":0,"satisfaction":3,"token_cost":0,"model_used":""}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	CreateSession(database).ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Errorf("expected 201 for user_hash exactly 8 chars, got %d", rec.Code)
	}
}

func TestCreateSession_InvalidOutcome(t *testing.T) {
	database := newTestDB(t)
	body := `{"user_hash":"abc123def456","task_type":"feature","plugins":"none","duration_mins":10,"outcome":"unknown","rework_score":0,"satisfaction":3,"token_cost":0,"model_used":""}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	CreateSession(database).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for invalid outcome, got %d", rec.Code)
	}
}

func TestCreateSession_SatisfactionOutOfRange(t *testing.T) {
	database := newTestDB(t)
	for _, sat := range []int{0, 6} {
		body := bytes.NewBufferString(`{"user_hash":"abc123def456","task_type":"feature","plugins":"none","duration_mins":10,"outcome":"complete","rework_score":0,"satisfaction":` + strconv.Itoa(sat) + `,"token_cost":0,"model_used":""}`)
		req := httptest.NewRequest(http.MethodPost, "/api/sessions", body)
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		CreateSession(database).ServeHTTP(rec, req)

		if rec.Code != http.StatusBadRequest {
			t.Errorf("expected 400 for satisfaction=%d, got %d", sat, rec.Code)
		}
	}
}

func TestCreateSession_DurationZeroOrNegative(t *testing.T) {
	database := newTestDB(t)
	for _, dur := range []int{0, -1} {
		body := bytes.NewBufferString(`{"user_hash":"abc123def456","task_type":"feature","plugins":"none","duration_mins":` + strconv.Itoa(dur) + `,"outcome":"complete","rework_score":0,"satisfaction":3,"token_cost":0,"model_used":""}`)
		req := httptest.NewRequest(http.MethodPost, "/api/sessions", body)
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		CreateSession(database).ServeHTTP(rec, req)

		if rec.Code != http.StatusBadRequest {
			t.Errorf("expected 400 for duration_mins=%d, got %d", dur, rec.Code)
		}
	}
}

func TestCreateSession_TokenCostOutOfRange(t *testing.T) {
	database := newTestDB(t)
	cases := []string{
		`{"user_hash":"abc123def456","task_type":"feature","plugins":"none","duration_mins":10,"outcome":"complete","rework_score":0,"satisfaction":3,"token_cost":-0.01,"model_used":""}`,
		`{"user_hash":"abc123def456","task_type":"feature","plugins":"none","duration_mins":10,"outcome":"complete","rework_score":0,"satisfaction":3,"token_cost":100.01,"model_used":""}`,
	}
	for _, body := range cases {
		req := httptest.NewRequest(http.MethodPost, "/api/sessions", bytes.NewBufferString(body))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		CreateSession(database).ServeHTTP(rec, req)

		if rec.Code != http.StatusBadRequest {
			t.Errorf("expected 400 for out-of-range token_cost, got %d: %s", rec.Code, body)
		}
	}
}

func TestCreateSession_InvalidJSON(t *testing.T) {
	database := newTestDB(t)
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", bytes.NewBufferString("not-json"))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	CreateSession(database).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for invalid JSON, got %d", rec.Code)
	}
}

func TestCreateSession_ReworkScoreNegative(t *testing.T) {
	database := newTestDB(t)
	body := `{"user_hash":"abc123def456","task_type":"feature","plugins":"none","duration_mins":10,"outcome":"complete","rework_score":-1,"satisfaction":3,"token_cost":0,"model_used":""}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	CreateSession(database).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for rework_score=-1, got %d", rec.Code)
	}
}

func TestCreateSession_ReworkScoreOutOfRange(t *testing.T) {
	database := newTestDB(t)
	body := `{"user_hash":"abc123def456","task_type":"feature","plugins":"none","duration_mins":10,"outcome":"complete","rework_score":9,"satisfaction":3,"token_cost":0,"model_used":""}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	CreateSession(database).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", rec.Code)
	}
}

func TestListSessions_Empty(t *testing.T) {
	database := newTestDB(t)
	rec := doGet(t, ListSessions(database), "/api/sessions")

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var sessions []models.Session
	if err := json.Unmarshal(rec.Body.Bytes(), &sessions); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(sessions) != 0 {
		t.Errorf("expected empty, got %d", len(sessions))
	}
}

func TestListSessions_FilterByUserHash(t *testing.T) {
	database := newTestDB(t)
	seedSession(t, database, models.Session{
		UserHash: "aaa111bbb222", TaskType: "feature", Plugins: "none",
		DurationMins: 10, Outcome: "complete", ReworkScore: 0, Satisfaction: 3,
	})
	seedSession(t, database, models.Session{
		UserHash: "zzz999yyy888", TaskType: "bug", Plugins: "none",
		DurationMins: 10, Outcome: "complete", ReworkScore: 0, Satisfaction: 3,
	})

	req := httptest.NewRequest(http.MethodGet, "/api/sessions?user_hash=aaa111bbb222", nil)
	rec := httptest.NewRecorder()
	ListSessions(database).ServeHTTP(rec, req)

	var sessions []models.Session
	json.Unmarshal(rec.Body.Bytes(), &sessions)
	if len(sessions) != 1 {
		t.Fatalf("expected 1 session for user_hash filter, got %d", len(sessions))
	}
	if sessions[0].UserHash != "aaa111bbb222" {
		t.Errorf("unexpected user_hash %q", sessions[0].UserHash)
	}
}

func TestDeleteSession_NotFound(t *testing.T) {
	database := newTestDB(t)
	r := chi.NewRouter()
	r.Delete("/api/sessions/{id}", DeleteSession(database))

	req := httptest.NewRequest(http.MethodDelete, "/api/sessions/nonexistent-id", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d", rec.Code)
	}
}

func TestDeleteSession_Valid(t *testing.T) {
	database := newTestDB(t)
	sess := models.Session{
		ID: "test-id-123", UserHash: "abc123def456", TaskType: "feature",
		Plugins: "none", DurationMins: 10, Outcome: "complete",
		ReworkScore: 0, Satisfaction: 3,
	}
	seedSession(t, database, sess)

	r := chi.NewRouter()
	r.Delete("/api/sessions/{id}", DeleteSession(database))

	req := httptest.NewRequest(http.MethodDelete, "/api/sessions/test-id-123", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Errorf("expected 204, got %d", rec.Code)
	}
}
