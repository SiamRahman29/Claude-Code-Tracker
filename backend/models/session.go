package models

import "time"

type Session struct {
	ID           string    `json:"id" db:"id"`
	UserHash     string    `json:"user_hash" db:"user_hash"`
	TaskType     string    `json:"task_type" db:"task_type"`
	Plugins      string    `json:"plugins" db:"plugins"`
	DurationMins int       `json:"duration_mins" db:"duration_mins"`
	Outcome      string    `json:"outcome" db:"outcome"`
	ReworkScore  int       `json:"rework_score" db:"rework_score"`
	Satisfaction int       `json:"satisfaction" db:"satisfaction"`
	TokenCost    float64   `json:"token_cost" db:"token_cost"`
	ModelUsed    string    `json:"model_used" db:"model_used"`
	Country      string    `json:"country" db:"country"`
	CreatedAt    time.Time `json:"created_at" db:"created_at"`
}

type Stats struct {
	TotalSessions       int                `json:"total_sessions"`
	TotalUsers          int                `json:"total_users"`
	AvgDurationMins     float64            `json:"avg_duration_mins"`
	AvgSatisfaction     float64            `json:"avg_satisfaction"`
	AvgTokenCost        float64            `json:"avg_token_cost"`
	CompletionRate      float64            `json:"completion_rate"`
	ReworkDistribution  map[string]int     `json:"rework_distribution"`
	TaskTypeDistribution map[string]int    `json:"task_type_distribution"`
	SessionsLast30Days  int                `json:"sessions_last_30_days"`
}

type PluginStat struct {
	Plugins        string  `json:"plugins"`
	SessionCount   int     `json:"session_count"`
	AvgSatisfaction float64 `json:"avg_satisfaction"`
	MinSatisfaction float64 `json:"min_satisfaction"`
	MaxSatisfaction float64 `json:"max_satisfaction"`
	AvgDurationMins float64 `json:"avg_duration_mins"`
	AvgReworkScore  float64 `json:"avg_rework_score"`
	AvgTokenCost    float64 `json:"avg_token_cost"`
	CompletionRate  float64 `json:"completion_rate"`
}
