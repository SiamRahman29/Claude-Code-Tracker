package handlers

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/SiamRahman29/cctracker/models"
)

var validTaskTypes = map[string]bool{
	"feature": true, "bug": true, "debug": true,
	"refactor": true, "docs": true, "other": true,
}
var validOutcomes = map[string]bool{
	"complete": true, "partial": true, "abandoned": true,
}

func CreateSession(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var s models.Session
		if err := json.NewDecoder(r.Body).Decode(&s); err != nil {
			jsonError(w, "invalid JSON", http.StatusBadRequest)
			return
		}

		if len(s.UserHash) < 8 || len(s.UserHash) > 16 {
			jsonError(w, "user_hash must be 8-16 chars", http.StatusBadRequest)
			return
		}
		if !validTaskTypes[s.TaskType] {
			jsonError(w, "invalid task_type", http.StatusBadRequest)
			return
		}
		if !validOutcomes[s.Outcome] {
			jsonError(w, "invalid outcome", http.StatusBadRequest)
			return
		}
		if s.ReworkScore < 0 || s.ReworkScore > 3 {
			jsonError(w, "rework_score must be 0-3", http.StatusBadRequest)
			return
		}
		if s.Satisfaction < 1 || s.Satisfaction > 5 {
			jsonError(w, "satisfaction must be 1-5", http.StatusBadRequest)
			return
		}
		if s.DurationMins <= 0 {
			jsonError(w, "duration_mins must be > 0", http.StatusBadRequest)
			return
		}
		if s.TokenCost < 0 || s.TokenCost > 100 {
			jsonError(w, "token_cost out of range", http.StatusBadRequest)
			return
		}

		s.ID = uuid.New().String()
		s.Country = "unknown"
		s.CreatedAt = time.Now().UTC()

		_, err := db.Exec(`
			INSERT INTO sessions (id,user_hash,task_type,plugins,duration_mins,outcome,rework_score,satisfaction,token_cost,model_used,country,created_at)
			VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`,
			s.ID, s.UserHash, s.TaskType, s.Plugins, s.DurationMins, s.Outcome,
			s.ReworkScore, s.Satisfaction, s.TokenCost, s.ModelUsed, s.Country, s.CreatedAt,
		)
		if err != nil {
			jsonError(w, "db error", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(s)
	}
}

func ListSessions(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		limit := 50
		offset := 0
		if l := r.URL.Query().Get("limit"); l != "" {
			if n, err := strconv.Atoi(l); err == nil && n > 0 {
				limit = n
			}
		}
		if o := r.URL.Query().Get("offset"); o != "" {
			if n, err := strconv.Atoi(o); err == nil && n >= 0 {
				offset = n
			}
		}

		query := `SELECT id,user_hash,task_type,plugins,duration_mins,outcome,rework_score,satisfaction,token_cost,model_used,country,created_at FROM sessions`
		args := []interface{}{}
		if uh := r.URL.Query().Get("user_hash"); uh != "" {
			query += " WHERE user_hash=?"
			args = append(args, uh)
		}
		query += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
		args = append(args, limit, offset)

		rows, err := db.Query(query, args...)
		if err != nil {
			jsonError(w, "db error", http.StatusInternalServerError)
			return
		}
		defer rows.Close()

		sessions := []models.Session{}
		for rows.Next() {
			var s models.Session
			if err := rows.Scan(&s.ID, &s.UserHash, &s.TaskType, &s.Plugins, &s.DurationMins,
				&s.Outcome, &s.ReworkScore, &s.Satisfaction, &s.TokenCost, &s.ModelUsed, &s.Country, &s.CreatedAt); err != nil {
				continue
			}
			sessions = append(sessions, s)
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(sessions)
	}
}

func DeleteSession(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := chi.URLParam(r, "id")
		if id == "" {
			jsonError(w, "missing id", http.StatusBadRequest)
			return
		}
		res, err := db.Exec("DELETE FROM sessions WHERE id=?", id)
		if err != nil {
			jsonError(w, "db error", http.StatusInternalServerError)
			return
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			jsonError(w, "not found", http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

func jsonError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
