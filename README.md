# cctracker

Claude Code productivity tracker. Automatically captures session metadata via hooks and sends it to a central Go backend for aggregated visualization.

**What it tracks (anonymously):**
- Session duration
- Task type (feature/bug/debug/refactor/docs)
- Outcome (complete/partial/abandoned)
- Rework score (0-3)
- Satisfaction (1-5, inferred by Claude from session tone)
- Plugins active (gstack, ruflo)
- Model used
- Token cost (optional, manual entry)

**What it never tracks:** file names, code content, task descriptions, conversation history.

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

### 3. Track a session

In any Claude Code session, type `/track` when done. Claude will classify the session, ask for token cost, and write a classification file. Exit Claude Code and the Stop hook POSTs it automatically.

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `PORT` | `8080` | Backend listen port |
| `DB_PATH` | `./cctracker.db` | SQLite database file path |
| `CCTRACKER_BACKEND` | _(required)_ | Backend URL for hook scripts |
| `CCTRACKER_DEBUG` | _(unset)_ | Set to `1` to enable debug logging to `~/.cctracker/debug.log` |

## Self-hosting

The backend is a single CGO-free Go binary with an embedded dashboard.

```bash
cd backend
CGO_ENABLED=0 go build -o cctracker .
./cctracker
```

Set `DB_PATH` to a persistent path (e.g., `/var/lib/cctracker/data.db`).

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

## Privacy model

- User identity = SHA-256 of `hostname + username`, first 12 hex chars
- No reverse lookup possible — one-way hash
- No IP addresses stored
- No conversation content ever transmitted

## Project structure

```
cctracker/
├── backend/          # Go + Chi + SQLite API server + embedded dashboard
│   ├── main.go
│   ├── handlers/     # HTTP handlers
│   ├── models/       # Session struct + stats types
│   ├── db/           # SQLite init (WAL mode)
│   ├── middleware/   # CORS + per-IP rate limiting
│   └── dashboard/    # Single-file HTML dashboard (no external deps)
└── skill/            # Claude Code skill
    ├── SKILL.md      # Skill instructions (triggered by /track)
    ├── hooks/        # session-start.sh + session-end.sh
    └── install.sh    # One-command installer
```
