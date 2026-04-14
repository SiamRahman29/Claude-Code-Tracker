# Changelog

## [0.1.1.0] - 2026-04-14

### Added
- Always-on session tracking (`CCTRACKER_ENABLED=1`): all sessions recorded automatically without any manual steps
- `session-watchdog.sh`: background daemon that detects Claude Code process exit by any method (Ctrl+C, terminal close, `/exit`) and finalizes the session
- `session-finalize.sh`: shared finalization script with atomic lockfile dedup — concurrent callers post exactly once
- `skill/test/hooks.sh`: 7 integration tests covering lockfile dedup, duration guards, missing session file, always-on no-op, and token accumulation
- `install.sh`: prompts for `CCTRACKER_ENABLED` during setup; copies new hook files automatically

### Fixed
- `token-accumulator.sh`: tokens were never accumulated (read from `.pid-$$.id` which was never created); now correctly reads `.current_id`
- `session-end.sh`: in always-on mode, Stop hook is a pure no-op (watchdog is the sole finalization path, preventing 20+ duplicate POSTs per session)
- `session-finalize.sh` / `session-end.sh`: `hostname` command not available on some WSL installs; falls back to `uname -n` then `localhost`

### Changed
- `skill/SKILL.md`: removed `/track` manual classification flow; documents always-on behavior
- Session data now includes token cost computed from accumulated per-turn token counts

## [0.1.0.0] - 2026-04-12

### Added
- 22 handler tests covering all validation boundaries and happy paths (`backend/handlers/`)
- CLAUDE.md: gstack skill routing rules for AI-assisted development workflows

### Fixed
- `session-end.sh`: sessions where `start_ts` failed to parse now correctly skipped (max 1440 min cap prevents posting absurd durations)
- `session-end.sh`: fallback `user_hash` changed from "unknown" (7 chars, failed backend validation) to "fallbackuser"
- `session-start.sh`: JSON session file now written via Python instead of bash heredoc (prevents corruption if model name contains special characters)
- Backend: `ListSessions` response now capped at 500 results; scan errors surface correctly
- Backend: `plugins` and `model_used` fields now have a length cap (64 and 100 chars)
- Backend: SQLite connection pool set to 1 (`SetMaxOpenConns`) to serialize writes correctly

## [0.1.0.0-initial] - 2026-04-11

### Added
- Go + Chi + SQLite backend with embedded dashboard (single binary, zero ops)
- `POST /api/sessions` — submit session data with full input validation and per-IP rate limiting (10 req/min)
- `GET /api/sessions` — list sessions with filtering by user_hash and pagination
- `DELETE /api/sessions/{id}` — delete a session by ID (correcting bad data)
- `GET /api/stats` — global aggregate stats (totals, averages, distributions, 30-day count)
- `GET /api/stats/plugins` — per-plugin-combo breakdown sorted by avg satisfaction
- Embedded single-file dashboard with dark theme, no external dependencies
- Dashboard: verdict section (is this plugin worth it?), plugin comparison table with min/avg/max satisfaction, hero stats, task type bar chart, rework donut chart
- Dashboard: empty, loading, error, and sparse-data states implemented
- Claude Code skill (`/track`) — classifies session task type, outcome, rework score, satisfaction from conversation history
- `session-start.sh` hook — per-session state files keyed by UUID (concurrent session safe)
- `session-end.sh` hook — validates backend URL, reads per-session file, POSTs via python3 stdlib (no shell injection)
- `install.sh` — idempotent one-command installer that patches `settings.json` and `CLAUDE.md`
- CGO-free build (`modernc.org/sqlite`) — `CGO_ENABLED=0 go build` works on all platforms
- WAL mode on SQLite for concurrent read performance
- `CCTRACKER_DEBUG=1` debug logging to `~/.cctracker/debug.log`
- `CCTRACKER_BACKEND` validation at hook time — logs to `~/.cctracker/errors.log` if unset
- Portable hashing via `openssl dgst -sha256` (works on macOS + Linux)
