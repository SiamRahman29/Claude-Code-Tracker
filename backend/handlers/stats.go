package handlers

import (
	"database/sql"
	"encoding/json"
	"net/http"

	"github.com/SiamRahman29/cctracker/models"
)

func GetStats(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		stats := models.Stats{
			ReworkDistribution:   make(map[string]int),
			TaskTypeDistribution: make(map[string]int),
		}

		// Aggregates
		row := db.QueryRow(`
			SELECT
				COUNT(*),
				COUNT(DISTINCT user_hash),
				COALESCE(AVG(duration_mins), 0),
				COALESCE(AVG(CAST(satisfaction AS REAL)), 0),
				COALESCE(AVG(token_cost), 0),
				COALESCE(CAST(SUM(CASE WHEN outcome='complete' THEN 1 ELSE 0 END) AS REAL) / NULLIF(COUNT(*), 0), 0),
				COUNT(CASE WHEN created_at >= datetime('now', '-30 days') THEN 1 END)
			FROM sessions`)
		if err := row.Scan(&stats.TotalSessions, &stats.TotalUsers, &stats.AvgDurationMins,
			&stats.AvgSatisfaction, &stats.AvgTokenCost, &stats.CompletionRate, &stats.SessionsLast30Days); err != nil {
			jsonError(w, "db error", http.StatusInternalServerError)
			return
		}

		// Rework distribution
		reworkRows, err := db.Query(`
			SELECT rework_score, COUNT(*) FROM sessions GROUP BY rework_score`)
		if err == nil {
			defer reworkRows.Close()
			nameMap := map[int]string{0: "none", 1: "minor", 2: "moderate", 3: "heavy"}
			for reworkRows.Next() {
				var score, count int
				if err := reworkRows.Scan(&score, &count); err == nil {
					if name, ok := nameMap[score]; ok {
						stats.ReworkDistribution[name] = count
					}
				}
			}
		}

		// Task type distribution
		taskRows, err := db.Query(`SELECT task_type, COUNT(*) FROM sessions GROUP BY task_type`)
		if err == nil {
			defer taskRows.Close()
			for taskRows.Next() {
				var taskType string
				var count int
				if err := taskRows.Scan(&taskType, &count); err == nil {
					stats.TaskTypeDistribution[taskType] = count
				}
			}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(stats)
	}
}

func GetPluginStats(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`
			SELECT
				plugins,
				COUNT(*) as session_count,
				COALESCE(AVG(CAST(satisfaction AS REAL)), 0) as avg_satisfaction,
				COALESCE(MIN(CAST(satisfaction AS REAL)), 0) as min_satisfaction,
				COALESCE(MAX(CAST(satisfaction AS REAL)), 0) as max_satisfaction,
				COALESCE(AVG(duration_mins), 0) as avg_duration,
				COALESCE(AVG(CAST(rework_score AS REAL)), 0) as avg_rework,
				COALESCE(AVG(token_cost), 0) as avg_cost,
				COALESCE(CAST(SUM(CASE WHEN outcome='complete' THEN 1 ELSE 0 END) AS REAL) / NULLIF(COUNT(*), 0), 0) as completion_rate
			FROM sessions
			GROUP BY plugins
			ORDER BY avg_satisfaction DESC`)
		if err != nil {
			jsonError(w, "db error", http.StatusInternalServerError)
			return
		}
		defer rows.Close()

		result := []models.PluginStat{}
		for rows.Next() {
			var ps models.PluginStat
			if err := rows.Scan(&ps.Plugins, &ps.SessionCount, &ps.AvgSatisfaction,
				&ps.MinSatisfaction, &ps.MaxSatisfaction,
				&ps.AvgDurationMins, &ps.AvgReworkScore, &ps.AvgTokenCost, &ps.CompletionRate); err != nil {
				continue
			}
			result = append(result, ps)
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(result)
	}
}

func Health(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}
