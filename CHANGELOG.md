# Changelog

## [0.1.0.0] - 2026-04-11

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
