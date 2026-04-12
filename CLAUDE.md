# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Backend (Go)

```bash
# Run in development
cd backend && go run main.go

# Build a CGO-free binary
cd backend && CGO_ENABLED=0 go build -o cctracker .

# Run tests
cd backend && go test ./...

# Run a single package's tests
cd backend && go test ./handlers/...
```

### Skill installation

```bash
cd skill && CCTRACKER_BACKEND=http://localhost:8080 bash install.sh
```

## Architecture

cctracker has two independently deployable parts:

### Backend (`backend/`)

A Go HTTP server using **chi** for routing and **modernc.org/sqlite** (CGO-free) for storage. Entry point is `main.go`, which wires up routes and passes a `*sql.DB` to each handler via closure.

- `db/db.go` — initializes SQLite in WAL mode, runs schema migrations
- `handlers/session.go` — CRUD for sessions; validates all fields before insert
- `handlers/stats.go` — aggregate query handlers for the dashboard charts
- `models/session.go` — `Session` struct (the canonical data shape) and stats response types
- `middleware/cors.go` — CORS; `middleware/` also contains per-IP rate limiting (10 req/min on `POST /api/sessions`) via `golang.org/x/time/rate`
- `dashboard/index.html` — single-file dashboard embedded into the binary via `//go:embed`; no external dependencies, no build step

The server is intentionally stateless — `*sql.DB` is the only shared state, passed explicitly to every handler.

### Skill + Hooks (`skill/`)

A Claude Code skill triggered by `/track`. The data flow at session end is:

1. **session-start.sh** (Claude Code `Start` hook) — writes `~/.cctracker/sessions/<uuid>.json` containing `start_ts`, `model`, and detected plugins (gstack, ruflo).
2. **`/track` skill** (`SKILL.md`) — Claude classifies the session and writes `~/.cctracker/classification_<session_id>.json` with `task_type`, `outcome`, `rework_score`, `satisfaction`, `token_cost`.
3. **session-end.sh** (Claude Code `Stop` hook) — reads both files, computes duration, hashes `hostname+username` to a 12-char `user_hash`, and POSTs to `$CCTRACKER_BACKEND/api/sessions` via Python's `urllib` (no dependencies). Cleanup is always performed.

**Security note in hooks:** shell variables are passed to the Python heredoc exclusively via environment variables (`_CC_*`) to prevent shell injection.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | Backend listen port |
| `DB_PATH` | `./cctracker.db` | SQLite file path |
| `CCTRACKER_BACKEND` | _(required)_ | URL hooks POST to |
| `CCTRACKER_DEBUG` | _(unset)_ | Set to `1` for debug log at `~/.cctracker/debug.log` |

## Key constraints

- The backend binary must remain CGO-free (`modernc.org/sqlite`, not `mattn/go-sqlite3`).
- The dashboard must remain a single HTML file with no external dependencies or build pipeline.
- The hooks must work with only `bash`, `openssl`, `python3` (stdlib only), and optionally `jq` — no npm, no Go toolchain required on the user's machine.
- No conversation content, file names, or task descriptions are ever transmitted — only the categorical fields in `models.Session`.

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
