# cctracker

Claude Code productivity tracker. Automatically captures session metadata via hooks and sends it to a central Go backend for aggregated visualization.

**What it tracks (anonymously):**
- Session duration
- Model used
- Token cost (computed from per-turn token counts)
- Plugins active (gstack, ruflo)

**What it never tracks:** task type, outcome, satisfaction ratings, file names, code content, task descriptions, or conversation history.

## Quick start

### 1. Start the backend

```bash
cd backend
go run main.go
```

Listens on `:8080`. Open `http://localhost:8080` for the dashboard.

### 2. Install the skill and hooks

```bash
cd skill
CCTRACKER_BACKEND=http://localhost:8080 bash install.sh
```

The installer will ask if you want always-on tracking enabled (default: yes). That's it — no further setup required.

### 3. Use Claude Code normally

With `CCTRACKER_ENABLED=1` (set by the installer), every session is recorded automatically. No manual steps. Exit however you want — `/exit`, Ctrl+C, or closing the terminal.

## How it works

```
Session starts
  → session-start.sh generates UUID, writes session JSON, starts background watchdog

Per tool call
  → token-accumulator.sh appends token counts to a per-session file

Session ends (any method: /exit, Ctrl+C, terminal close)
  → watchdog detects Claude Code PID is gone
  → session-finalize.sh computes duration + token cost, POSTs once, cleans up
```

The watchdog polls the Claude Code PID every 5 seconds. When it detects the process is gone, it finalizes the session. An atomic lockfile (`set -C` noclobber) ensures exactly one POST per session regardless of how many concurrent exit paths fire.

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `PORT` | `8080` | Backend listen port |
| `DB_PATH` | `./cctracker.db` | SQLite database file path |
| `CCTRACKER_BACKEND` | _(required)_ | Backend URL for hook scripts |
| `CCTRACKER_ENABLED` | `0` | Set to `1` to enable always-on automatic tracking |
| `CCTRACKER_DEBUG` | _(unset)_ | Set to `1` to enable debug logging to `~/.cctracker/debug.log` |

Both `CCTRACKER_BACKEND` and `CCTRACKER_ENABLED` are written to `~/.claude/settings.json` by the installer.

## Self-hosting

The backend is a single CGO-free Go binary with an embedded dashboard.

```bash
cd backend
CGO_ENABLED=0 go build -o cctracker .
./cctracker
```

Set `DB_PATH` to a persistent path (e.g., `/var/lib/cctracker/data.db`).

## Testing

```bash
# Backend (Go)
cd backend && go test ./...

# Hook integration tests (requires python3 + openssl)
bash skill/test/hooks.sh
```

The hook test suite spins up a local mock HTTP server, runs each hook in an isolated temp directory, and verifies POST counts, lockfile behavior, and token accumulation.

## API

```
POST   /api/sessions           Submit a session
GET    /api/sessions           List sessions (?user_hash=&limit=50&offset=0)
DELETE /api/sessions/{id}      Delete a session by ID
GET    /api/stats              Global aggregate stats
GET    /api/stats/plugins      Per-plugin-combo breakdown
GET    /health                 {"status":"ok"}
GET    /                       Dashboard
```

Rate limiting: `POST /api/sessions` is limited to 10 requests/minute per IP.

The backend is designed for personal/localhost use. If you expose it publicly, restrict `AllowedOrigins` in `backend/middleware/cors.go` to your specific frontend origin.

## Privacy model

- User identity = SHA-256 of `hostname + username`, first 12 hex chars
- No reverse lookup possible — one-way hash
- No IP addresses stored
- No conversation content ever transmitted

## Project structure

```
cctracker/
├── backend/              # Go + Chi + SQLite API server + embedded dashboard
│   ├── main.go
│   ├── handlers/         # HTTP handlers
│   ├── models/           # Session struct + stats types
│   ├── db/               # SQLite init (WAL mode)
│   ├── middleware/       # CORS + per-IP rate limiting
│   └── dashboard/        # Single-file HTML dashboard (no external deps)
└── skill/                # Claude Code hooks + installer
    ├── SKILL.md          # Documents always-on behavior
    ├── hooks/
    │   ├── session-start.sh       # Writes session JSON, launches watchdog
    │   ├── session-watchdog.sh    # Background daemon: detects process exit
    │   ├── session-finalize.sh    # Shared finalization: POST + lockfile dedup
    │   ├── session-end.sh         # Stop hook (no-op in always-on mode)
    │   └── token-accumulator.sh  # Appends per-turn token counts
    ├── test/
    │   └── hooks.sh      # Integration tests (7 tests, mock backend)
    └── install.sh        # One-command installer
```
