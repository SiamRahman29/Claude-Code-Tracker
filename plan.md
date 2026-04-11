<!-- /autoplan restore point: /home/siam/.gstack/projects/SiamRahman29-Claude-Code-Tracker/main-autoplan-restore-20260411-215512.md -->
# cctracker — Claude Code Productivity Tracker
## Complete Build Specification

You are building **cctracker**: a Claude Code skill + Go backend that automatically tracks
Claude Code session productivity and sends it to a central server for aggregated visualization.

Work through this spec top-to-bottom. Complete each section fully before moving to the next.
Ask no clarifying questions — all decisions are made below.

---

## 1. Project Structure

```
cctracker/
├── backend/                  # Go + Chi API server
│   ├── main.go
│   ├── go.mod
│   ├── go.sum
│   ├── handlers/
│   │   ├── session.go        # POST /api/sessions, GET /api/sessions
│   │   └── stats.go          # GET /api/stats, GET /api/stats/plugins
│   ├── models/
│   │   └── session.go        # Session struct + DB schema
│   ├── db/
│   │   └── db.go             # SQLite setup via modernc.org/sqlite
│   ├── middleware/
│   │   └── cors.go           # CORS for dashboard requests
│   └── dashboard/
│       └── index.html        # Embedded static dashboard (Go embed)
│
├── skill/                    # Claude Code skill (installed into ~/.claude/)
│   ├── SKILL.md              # The skill instructions Claude reads
│   ├── hooks/
│   │   ├── session-start.sh  # Fires on Claude Code Start hook
│   │   └── session-end.sh    # Fires on Claude Code Stop hook
│   └── install.sh            # One-command installer
│
└── README.md
```

---

## 2. Backend — Go + Chi

### 2.1 Dependencies

```
github.com/go-chi/chi/v5
github.com/go-chi/cors
modernc.org/sqlite          # CGo-free SQLite driver
github.com/google/uuid
```

### 2.2 Data Model

```go
// models/session.go

type Session struct {
    ID            string    `json:"id" db:"id"`                         // UUID v4
    UserHash      string    `json:"user_hash" db:"user_hash"`           // SHA256 of hostname+username, first 12 chars — anonymous
    TaskType      string    `json:"task_type" db:"task_type"`           // feature|bug|debug|refactor|docs|other
    Plugins       string    `json:"plugins" db:"plugins"`               // comma-separated: "gstack,ruflo" or "none"
    DurationMins  int       `json:"duration_mins" db:"duration_mins"`
    Outcome       string    `json:"outcome" db:"outcome"`               // complete|partial|abandoned
    ReworkScore   int       `json:"rework_score" db:"rework_score"`     // 0=none 1=minor 2=moderate 3=heavy
    Satisfaction  int       `json:"satisfaction" db:"satisfaction"`     // 1–5
    TokenCost     float64   `json:"token_cost" db:"token_cost"`         // USD, 0 if unknown
    ModelUsed     string    `json:"model_used" db:"model_used"`         // e.g. claude-sonnet-4-5
    Country       string    `json:"country" db:"country"`               // derived from IP via simple lookup, or "unknown"
    CreatedAt     time.Time `json:"created_at" db:"created_at"`
}
```

### 2.3 Database

Use **modernc.org/sqlite** (no CGo required). Single file: `cctracker.db`.

```sql
CREATE TABLE IF NOT EXISTS sessions (
    id            TEXT PRIMARY KEY,
    user_hash     TEXT NOT NULL,
    task_type     TEXT NOT NULL DEFAULT 'other',
    plugins       TEXT NOT NULL DEFAULT 'none',
    duration_mins INTEGER NOT NULL DEFAULT 0,
    outcome       TEXT NOT NULL DEFAULT 'complete',
    rework_score  INTEGER NOT NULL DEFAULT 0,
    satisfaction  INTEGER NOT NULL DEFAULT 3,
    token_cost    REAL NOT NULL DEFAULT 0,
    model_used    TEXT NOT NULL DEFAULT '',
    country       TEXT NOT NULL DEFAULT 'unknown',
    created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_hash ON sessions(user_hash);
CREATE INDEX IF NOT EXISTS idx_created_at ON sessions(created_at);
CREATE INDEX IF NOT EXISTS idx_plugins ON sessions(plugins);
```

On DB init, also run: `PRAGMA journal_mode=WAL` for concurrent read performance.

### 2.4 API Routes

```
POST   /api/sessions           Submit a session
GET    /api/sessions           List sessions (query: ?user_hash=&limit=50&offset=0)
DELETE /api/sessions/{id}      Delete a session by ID (enables correcting bad data)
GET    /api/stats              Global aggregate stats
GET    /api/stats/plugins      Per-plugin-combo breakdown
GET    /                       Serve embedded dashboard HTML
GET    /health                 {"status":"ok"}
```

#### POST /api/sessions

Request body (JSON):
```json
{
  "user_hash": "a3f9b2c1d8e4",
  "task_type": "feature",
  "plugins": "gstack",
  "duration_mins": 42,
  "outcome": "complete",
  "rework_score": 1,
  "satisfaction": 4,
  "token_cost": 0.24,
  "model_used": "claude-sonnet-4-5"
}
```

Validation rules:
- `task_type` must be one of: feature, bug, debug, refactor, docs, other
- `outcome` must be one of: complete, partial, abandoned
- `rework_score` must be 0–3
- `satisfaction` must be 1–5
- `duration_mins` must be > 0
- `user_hash` must be non-empty, 8–16 chars
- Reject if `token_cost` < 0 or > 100 (sanity check)

Respond `201 Created` with the saved session JSON.
Respond `400 Bad Request` with `{"error": "..."}` on validation failure.

#### GET /api/stats

Response:
```json
{
  "total_sessions": 1247,
  "total_users": 89,
  "avg_duration_mins": 38.4,
  "avg_satisfaction": 3.8,
  "avg_token_cost": 0.31,
  "completion_rate": 0.74,
  "rework_distribution": {
    "none": 312,
    "minor": 498,
    "moderate": 291,
    "heavy": 146
  },
  "task_type_distribution": {
    "feature": 423,
    "bug": 198,
    ...
  },
  "sessions_last_30_days": 341
}
```

#### GET /api/stats/plugins

Response — array sorted by avg_satisfaction desc:
```json
[
  {
    "plugins": "gstack",
    "session_count": 312,
    "avg_satisfaction": 4.2,
    "avg_duration_mins": 34.1,
    "avg_rework_score": 0.9,
    "avg_token_cost": 0.22,
    "completion_rate": 0.81
  },
  ...
]
```

### 2.5 CORS + Rate Limiting

Allow all origins (`*`) — this is a public API. Use `github.com/go-chi/cors`.

Apply per-IP rate limiting on `POST /api/sessions`: 10 requests/minute using a token bucket.
Use `golang.org/x/time/rate` (stdlib-adjacent) or a simple in-memory map with sync.Mutex.
Rate limit only the write endpoint — reads are cheap and low-risk.

### 2.6 Configuration

Read from environment variables with defaults:

```go
PORT     = getEnv("PORT", "8080")
DB_PATH  = getEnv("DB_PATH", "./cctracker.db")
```

### 2.7 main.go structure

```go
func main() {
    db := db.Init(dbPath)
    r := chi.NewRouter()
    r.Use(middleware.Logger)
    r.Use(middleware.Recoverer)
    r.Use(cors.Handler(...))
    r.Post("/api/sessions", handlers.CreateSession(db))
    r.Get("/api/sessions", handlers.ListSessions(db))
    r.Get("/api/stats", handlers.GetStats(db))
    r.Get("/api/stats/plugins", handlers.GetPluginStats(db))
    r.Get("/health", handlers.Health)
    r.Handle("/*", http.FileServer(http.FS(dashboardFS))) // embedded
    log.Fatal(http.ListenAndServe(":"+port, r))
}
```

### 2.8 Dashboard (embedded HTML)

Embed `dashboard/index.html` using Go's `//go:embed` directive in main.go.

The dashboard is a single self-contained HTML file with no external dependencies
(inline CSS + JS only — no CDN calls, no build step). It fetches data from the
same origin at `/api/stats` and `/api/stats/plugins` on load.

The dashboard must display:

**Layout order (most actionable first):**

1. **"Is it worth it?" verdict section** — rendered at the TOP. For each plugin combo
   with ≥20 sessions, compare to the "none" baseline:
   - If avg_satisfaction > none + 0.3: "✓ gstack appears to help (+X pts satisfaction)"
   - If avg_satisfaction < none - 0.3: "✗ ruflo appears to hurt satisfaction vs baseline"
   - Otherwise: "~ No significant difference detected yet"
   - For combos with <20 sessions: show "📊 N/20 sessions to unlock verdict" progress bar.
   - For "none" baseline rows: show "Baseline — N sessions"

2. **Plugin comparison table** — one row per plugin combo with: sessions, avg satisfaction
   (min/avg/max display instead of single number), avg duration, avg rework score,
   completion %, avg token cost. Dim rows with <20 sessions and label "(low data)".

3. **Hero stats row** — Total Sessions, Total Users, Avg Duration, Completion Rate.
   (Avg Satisfaction removed from hero — single number without distribution is misleading.)

4. **Task type bar chart** — horizontal bars, SVG, inline

5. **Rework distribution donut** — SVG, inline

**Required states (must implement all):**

- **Empty state** (0 sessions): centered message "No sessions yet. Run `/track` in a
  Claude Code session to start tracking."
- **Loading state**: simple text "Loading..." replacing each section until fetch completes.
- **Error state**: if fetch returns non-200 or throws, show red banner at top:
  "Dashboard error: [status code]. Is the backend running?"
- **Sparse data** (1-19 sessions for a plugin combo): show rows with "(low data)" label
  and dimmed styling.

Design: dark theme, `system-ui` as primary font, monospace only for numbers that need
alignment. Apply `font-variant-numeric: tabular-nums` on stats columns. No external fonts.

---

## 3. Skill — Claude Code Integration

### 3.1 How Claude Code hooks work

Claude Code fires hooks at specific lifecycle events. They are configured in
`~/.claude/settings.json` under the `hooks` key. Each hook specifies a shell
command to run. Relevant events:

- `Start` — fires when a new Claude Code session begins
- `Stop` — fires when a session ends (user exits or `/exit`)
- `PostToolUse` — fires after every tool call (Bash, Edit, Write, etc.)

Hook commands receive context as a JSON object on stdin.

### 3.2 What the hooks capture

**Concurrent session support:** State is keyed by SESSION_ID, not a single shared file.
Each session writes to `~/.cctracker/sessions/${SESSION_ID}.json`. The Stop hook finds
the matching file by SESSION_ID (passed via env or stored in a temp file per PID).

**session-start.sh** (runs on `Start` hook):
- Records `SESSION_START_TS` and `SESSION_ID` (UUID) to `~/.cctracker/sessions/${SESSION_ID}.json`
- Records `CLAUDE_MODEL` from the stdin JSON if available
- Detects active plugins by checking for known config files:
  - gstack: `~/.claude/skills/gstack/` directory exists
  - ruflo: check `~/.claude/settings.json` for `mcp__ruflo` or `ruv-swarm` keys

```bash
#!/usr/bin/env bash
# hooks/session-start.sh
# Receives Claude Code hook context on stdin
set -euo pipefail

mkdir -p ~/.cctracker/sessions

# Parse stdin JSON for model info (jq preferred, python3 fallback)
STDIN=$(cat)
if command -v jq >/dev/null 2>&1; then
    MODEL=$(echo "$STDIN" | jq -r '.model // "unknown"' 2>/dev/null || echo "unknown")
else
    MODEL=$(echo "$STDIN" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('model','unknown'))" 2>/dev/null || echo "unknown")
fi

# Detect plugins
PLUGINS=""
[ -d ~/.claude/skills/gstack ] && PLUGINS="${PLUGINS}gstack,"
grep -q "ruv-swarm\|ruflo\|ruvnet" ~/.claude/settings.json 2>/dev/null && PLUGINS="${PLUGINS}ruflo,"
PLUGINS="${PLUGINS%,}"
[ -z "$PLUGINS" ] && PLUGINS="none"

# Generate session ID — uuidgen is available on Linux and macOS
SESSION_ID=$(uuidgen 2>/dev/null || python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$$")
START_TS=$(date +%s)

# Write per-session state file (safe for concurrent sessions)
SESSION_FILE=~/.cctracker/sessions/${SESSION_ID}.json
cat > "$SESSION_FILE" << EOF
{
  "session_id": "${SESSION_ID}",
  "start_ts": ${START_TS},
  "model": "${MODEL}",
  "plugins": "${PLUGINS}"
}
EOF

# Store session ID for this shell process so session-end.sh can find it
echo "$SESSION_ID" > ~/.cctracker/sessions/.pid-$$.id

[ -n "${CCTRACKER_DEBUG:-}" ] && echo "$(date): cctracker start — session $SESSION_ID model=$MODEL plugins=$PLUGINS" >> ~/.cctracker/debug.log

exit 0
```

**session-end.sh** (runs on `Stop` hook):
- Reads `~/.cctracker/sessions/${SESSION_ID}.json`
- Calculates duration
- Reads classification written by `/track` skill (see section 3.3)
- POSTs to the backend (fire and forget)
- Cleans up session file

```bash
#!/usr/bin/env bash
# hooks/session-end.sh
set -euo pipefail

DEBUG_LOG=~/.cctracker/debug.log
ERR_LOG=~/.cctracker/errors.log

_log_debug() { [ -n "${CCTRACKER_DEBUG:-}" ] && echo "$(date): cctracker: $*" >> "$DEBUG_LOG"; }
_log_err()   { echo "$(date): cctracker ERROR: $*" >> "$ERR_LOG"; }

# Validate backend URL
if [ -z "${CCTRACKER_BACKEND:-}" ] || [ "${CCTRACKER_BACKEND}" = "https://your-server.com" ]; then
    _log_err "CCTRACKER_BACKEND not set or still placeholder — skipping POST. Set it in your shell profile."
    exit 0
fi
BACKEND_URL="$CCTRACKER_BACKEND"

# Find session file for this process
PID_FILE=~/.cctracker/sessions/.pid-$$.id
[ ! -f "$PID_FILE" ] && { _log_debug "No session file for PID $$"; exit 0; }
SESSION_ID=$(cat "$PID_FILE")
SESSION_FILE=~/.cctracker/sessions/${SESSION_ID}.json
[ ! -f "$SESSION_FILE" ] && { _log_err "Session file missing: $SESSION_FILE"; rm -f "$PID_FILE"; exit 0; }

# Parse session file (single python3 call — DRY)
if command -v jq >/dev/null 2>&1; then
    START_TS=$(jq -r '.start_ts' "$SESSION_FILE")
    MODEL=$(jq -r '.model' "$SESSION_FILE")
    PLUGINS=$(jq -r '.plugins' "$SESSION_FILE")
else
    read START_TS MODEL PLUGINS <<< "$(python3 - <<PYEOF
import json
d = json.load(open('$SESSION_FILE'))
print(d['start_ts'], d.get('model','unknown'), d.get('plugins','none'))
PYEOF
)"
fi

END_TS=$(date +%s)
DURATION=$(( (END_TS - START_TS) / 60 ))

# Guard: skip nonsensical durations
[ "$DURATION" -le 0 ] && { _log_debug "Duration <= 0, skipping post"; rm -f "$SESSION_FILE" "$PID_FILE"; exit 0; }

# Compute anonymous user hash (portable: works on macOS + Linux)
USER_HASH=$(echo -n "$(hostname)$(whoami)" | openssl dgst -sha256 2>/dev/null | awk '{print $2}' | cut -c1-12)
[ -z "$USER_HASH" ] && USER_HASH="unknown"

# Read classification written by /track skill (see 3.3)
CLASSIFICATION=~/.cctracker/classification_${SESSION_ID}.json
TASK_TYPE="other"; OUTCOME="complete"; REWORK_SCORE=1; SATISFACTION=3; TOKEN_COST=0

if [ -f "$CLASSIFICATION" ]; then
    if command -v jq >/dev/null 2>&1; then
        TASK_TYPE=$(jq -r '.task_type // "other"' "$CLASSIFICATION")
        OUTCOME=$(jq -r '.outcome // "complete"' "$CLASSIFICATION")
        REWORK_SCORE=$(jq -r '.rework_score // 1' "$CLASSIFICATION")
        SATISFACTION=$(jq -r '.satisfaction // 3' "$CLASSIFICATION")
        TOKEN_COST=$(jq -r '.token_cost // 0' "$CLASSIFICATION")
    else
        python3 - <<PYEOF
import json, os
d = json.load(open('$CLASSIFICATION'))
print(d.get('task_type','other'), d.get('outcome','complete'), d.get('rework_score',1), d.get('satisfaction',3), d.get('token_cost',0))
PYEOF
        # Re-read into vars (simplified — implementer can expand)
    fi
    rm -f "$CLASSIFICATION"
fi

_log_debug "Posting session $SESSION_ID: task=$TASK_TYPE outcome=$OUTCOME duration=${DURATION}m satisfaction=$SATISFACTION"

# POST to backend (fire and forget — never block the user)
# All shell vars passed as env vars; Python reads from os.environ (no shell injection)
export _CC_USER_HASH="$USER_HASH"
export _CC_TASK_TYPE="$TASK_TYPE"
export _CC_PLUGINS="$PLUGINS"
export _CC_DURATION="$DURATION"
export _CC_OUTCOME="$OUTCOME"
export _CC_REWORK="$REWORK_SCORE"
export _CC_SAT="$SATISFACTION"
export _CC_COST="$TOKEN_COST"
export _CC_MODEL="$MODEL"
export _CC_SESSION="$SESSION_ID"
export _CC_BACKEND="$BACKEND_URL"

python3 - <<'PYEOF'
import urllib.request, json, os

payload = {
    "user_hash":    os.environ["_CC_USER_HASH"],
    "task_type":    os.environ["_CC_TASK_TYPE"],
    "plugins":      os.environ["_CC_PLUGINS"],
    "duration_mins":int(os.environ["_CC_DURATION"]),
    "outcome":      os.environ["_CC_OUTCOME"],
    "rework_score": int(os.environ["_CC_REWORK"]),
    "satisfaction": int(os.environ["_CC_SAT"]),
    "token_cost":   float(os.environ["_CC_COST"]),
    "model_used":   os.environ["_CC_MODEL"],
}
try:
    req = urllib.request.Request(
        os.environ["_CC_BACKEND"] + "/api/sessions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    urllib.request.urlopen(req, timeout=5)
except Exception as e:
    pass  # Never block the user
PYEOF

# Cleanup
rm -f "$SESSION_FILE" "$PID_FILE"
exit 0
```

### 3.3 SKILL.md — Classification at session end

This is the file Claude reads. It tells Claude what to do when the user types `/track`.

Place at: `~/.claude/skills/cctracker/SKILL.md`

Also add to `~/.claude/CLAUDE.md`:
```
@~/.claude/skills/cctracker/SKILL.md
```

The SKILL.md content:

```markdown
# cctracker skill

## Trigger
When the user types `/track`. Explicit invocation only — do NOT auto-trigger based on
phrases like "done", "thanks", or "ship it". Those appear mid-session constantly and
produce false positives. Only run when the user explicitly asks.

## What to do

1. Review the full conversation history silently.

2. Determine:
   - **task_type**: one of feature|bug|debug|refactor|docs|other
     (what was the primary nature of the work?)
   - **outcome**: one of complete|partial|abandoned
     (did the user achieve what they set out to do?)
   - **rework_score**: integer 0–3
     - 0 = Claude got it right first time, no corrections needed
     - 1 = 1–2 minor corrections
     - 2 = several rounds of back-and-forth or significant corrections
     - 3 = heavy rework, user expressed frustration or had to restart
   - **satisfaction**: integer 1–5
     - Infer from tone: frustrated/repeated corrections = 2, smooth/praise = 5

3. Ask the user ONE question only:
   "Before we close — quick tracking question. Token cost this session (check your
   API dashboard), or press Enter to skip: $"

   If they provide a number, use it. If they press Enter or say "skip", use 0.

4. Find the session ID for this session. Check `~/.cctracker/sessions/.pid-*.id`
   for the most recently modified file and read the session ID from it.
   Write the classification to `~/.cctracker/classification_${SESSION_ID}.json`:

```json
{
  "task_type": "feature",
  "outcome": "complete",
  "rework_score": 1,
  "satisfaction": 4,
  "token_cost": 0.24
}
```

Use the Write tool. If no session ID can be found, write to
`~/.cctracker/classification_latest.json` and session-end.sh will check both paths.

5. Say: "✓ Session logged. Run `/exit` when ready — the hook will POST the data."

## Privacy note
Never include task descriptions, file names, or any content from the conversation
in the classification. Only the categorical fields above are transmitted.
```

### 3.4 install.sh

```bash
#!/usr/bin/env bash
# install.sh — One-command cctracker setup

set -e

SKILL_DIR=~/.claude/skills/cctracker
HOOKS_DIR=~/.cctracker/hooks
CLAUDE_SETTINGS=~/.claude/settings.json
CLAUDE_MD=~/.claude/CLAUDE.md

echo "Installing cctracker..."

# 1. Create directories
mkdir -p "$SKILL_DIR" "$HOOKS_DIR" ~/.cctracker

# 2. Copy skill
cp SKILL.md "$SKILL_DIR/SKILL.md"

# 3. Copy and chmod hooks
cp hooks/session-start.sh "$HOOKS_DIR/session-start.sh"
cp hooks/session-end.sh "$HOOKS_DIR/session-end.sh"
chmod +x "$HOOKS_DIR/session-start.sh"
chmod +x "$HOOKS_DIR/session-end.sh"

# 4. Patch CLAUDE.md (add @import if not already present)
IMPORT_LINE="@~/.claude/skills/cctracker/SKILL.md"
if [ -f "$CLAUDE_MD" ]; then
    grep -qF "$IMPORT_LINE" "$CLAUDE_MD" || echo "$IMPORT_LINE" >> "$CLAUDE_MD"
else
    echo "$IMPORT_LINE" > "$CLAUDE_MD"
fi

# 5. Patch settings.json hooks
# Uses Python to safely merge hooks without clobbering existing config
python3 - << 'PYEOF'
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")
hooks_dir = os.path.expanduser("~/.cctracker/hooks")

if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
else:
    settings = {}

new_hooks = {
    "Start": [{"matcher": "", "hooks": [{"type": "command", "command": f"{hooks_dir}/session-start.sh"}]}],
    "Stop":  [{"matcher": "", "hooks": [{"type": "command", "command": f"{hooks_dir}/session-end.sh"}]}]
}

if "hooks" not in settings:
    settings["hooks"] = {}

for event, hook_list in new_hooks.items():
    if event not in settings["hooks"]:
        settings["hooks"][event] = hook_list
    else:
        # Append only if cctracker hook not already present
        existing_cmds = [h["command"] for entry in settings["hooks"][event] for h in entry.get("hooks", [])]
        if hook_list[0]["hooks"][0]["command"] not in existing_cmds:
            settings["hooks"][event].extend(hook_list)

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)

print("settings.json patched.")
PYEOF

echo ""
echo "✓ cctracker installed."
echo ""
echo "Next: set your backend URL:"
echo "  export CCTRACKER_BACKEND=https://your-server.com"
echo "  (Add to ~/.zshrc or ~/.bashrc to persist)"
echo ""
echo "Use /track in any Claude Code session to log it."
```

---

## 4. Build Order

Build in this exact order:

1. `backend/` — Go server first. Make sure `go build ./...` passes and the server
   starts cleanly with `go run main.go`.

2. `backend/dashboard/index.html` — build the dashboard HTML. Test by opening it
   in a browser pointed at a running local server.

3. `skill/hooks/session-start.sh` — write and manually test by running it with
   `echo '{"model":"claude-sonnet-4-5"}' | bash hooks/session-start.sh` and
   verifying `~/.cctracker/current.json` is created correctly.

4. `skill/hooks/session-end.sh` — test end-to-end by first running start, then
   manually creating `~/.cctracker/classification.json`, then running end and
   checking that the POST fires (use `nc -l 8080` or similar to catch it).

5. `skill/SKILL.md` — no code to test, but review it makes sense given the hooks.

6. `skill/install.sh` — run it and verify settings.json and CLAUDE.md are patched.

7. `README.md` — write last, covering: install, backend deploy, env vars,
   privacy model, how to self-host.

---

## 5. Key Decisions Already Made

| Decision | Choice | Reason |
|----------|--------|--------|
| Backend language | Go + Chi | Specified by user |
| Database | SQLite via modernc.org/sqlite | Zero-dependency, single file, easy to deploy |
| Auth | None | Public anonymized data — no accounts |
| Privacy | SHA256 hash of hostname+username | Anonymous but consistent per user |
| Task description | Never transmitted | Privacy — only categorical metadata |
| Dashboard | Embedded in Go binary | Zero ops, single binary deploy |
| Hook capture | Start + Stop hooks | Automatic, no user discipline required |
| Classification | SKILL.md + Claude judgment | Better than manual input forms |
| Plugin detection | Filesystem + settings.json scan | Works for gstack and ruflo |
| Failure mode | All errors silent | Never block the user |

---

## 6. Constraints

- The Go binary must compile with `CGO_ENABLED=0` (use modernc.org/sqlite, not mattn/go-sqlite3)
- All hook scripts must work on macOS and Linux
- Hook scripts must exit 0 always — never block Claude Code startup/shutdown
- No tracking of conversation content, file names, or task descriptions — ever
- The dashboard must work without JavaScript frameworks or CDN dependencies
- The install script must be idempotent — safe to run multiple times
- Hook scripts must use `openssl dgst -sha256` for hashing (not sha256sum — macOS incompatible)
- Hook scripts must NOT interpolate shell variables into Python code strings (use os.environ)
- Multiple concurrent Claude Code windows must work without data loss (per-session state files)
- `CCTRACKER_BACKEND` must be validated at hook time; log to `~/.cctracker/errors.log` if unset
- Debug mode: `CCTRACKER_DEBUG=1` → append events to `~/.cctracker/debug.log`

---

## 7. What NOT to build

- No user accounts or authentication
- No real-time websocket dashboard (polling on load is fine)
- No mobile app
- No npm/node dependency for the skill (pure bash + python3 stdlib only)
- No Docker file (out of scope for now)
- No tests (out of scope for now — ship working code first)

---

---

## /autoplan Review

_Generated 2026-04-11 by /autoplan v0.16.2.0_
_Mode: SELECTIVE EXPANSION | UI scope: yes | DX scope: yes_
_Outside voices: 4 subagents (CEO, Design, Eng, DX) — Codex unavailable_

---

## Phase 1: CEO Review

### System Audit Findings

- Brand new repo. Single initial commit. No existing code to reuse.
- No TODOS.md, no CLAUDE.md in project, no design doc.
- Plan is a complete build spec, not a partial one.

### 0A. Premise Challenge

**Premise 1: Tracking session metadata will yield meaningful productivity insights.**
Weak. The data quality problem undermines this entirely. The majority of sessions will have default values (`task_type=other`, `outcome=complete`, `rework_score=1`, `satisfaction=3`) because most users won't consistently run `/track`. Signal-to-noise will be poor.

**Premise 2: Claude can reliably infer its own quality from conversation tone.**
Invalid. A model rating its own performance has obvious incentive bias. The "detects wrapping up" heuristic will fire on common phrases mid-session. Both outside voices flagged this independently. The satisfaction/rework inference is methodologically unsound.

**Premise 3: Users will deploy a Go backend to use this skill.**
Wrong for most users. Requiring server infrastructure before the skill works eliminates the casual-user majority. The right default is local-only, with remote as opt-in.

**Premise 4: Plugin comparison is the valuable use case.**
Debatable. This is also the controversial angle — a vendor-influenced measurement instrument comparing vendor plugins to a baseline is not a neutral productivity tracker. This framing should be made explicit or removed.

**What would happen if we built nothing?** Developers would keep using gut feeling. That's the real pain point — and it's real. The tool idea is sound. The execution premises need work.

### 0B. Existing Code Leverage

Greenfield. Nothing to reuse. All sub-problems are net-new.

### 0C. Dream State

```
CURRENT STATE              THIS PLAN                    12-MONTH IDEAL
─────────────────────────────────────────────────────────────────────────
No tracking.               Manual /track at end of      Auto-classification
Gut-feel ROI               session → noisy aggregated   via git diff analysis.
assessment for             stats in a Go backend.       Personal + team
Claude Code.               Plugin comparison            dashboards. Zero
                           dashboard.                   user discipline needed.
```

This plan is a reasonable v1 toward the ideal — but it takes a wrong turn on the data quality problem. The 12-month ideal requires rethinking classification.

### 0C-bis. Implementation Alternatives

```
APPROACH A: Current plan (hooks + SKILL.md + Go backend)
  Summary: Claude Code hooks capture start/end. User runs /track to classify.
           Go backend aggregates globally. Embedded HTML dashboard.
  Effort:  M (human: ~3 days / CC: ~2 hrs)
  Risk:    Medium — most sessions will have default values; data quality is poor
  Pros:    Complete feature set. Multi-user aggregation. Plugin comparison.
  Cons:    Requires server deploy. Most sessions uncategorized. Fragile hooks.
  Reuses:  Nothing (greenfield)

APPROACH B: Local-only (no backend)
  Summary: Same hooks. SQLite on-device. localhost:8080 dashboard.
           No server needed. Individual insights only, no cross-user comparison.
  Effort:  S (human: ~1.5 days / CC: ~1 hr)
  Risk:    Low — no deploy, no network calls, no privacy concerns
  Pros:    Zero friction to install. Works immediately. No server costs.
  Cons:    No aggregate cross-user data. No plugin comparison at scale.
  Reuses:  Same Go server code, just binds localhost only

APPROACH C: Automatic classification via git analysis
  Summary: Instead of asking Claude to infer quality, read git diff at session end.
           New files → feature. Modified files → refactor/bug. Commit message → task type.
           Objective signals replace subjective satisfaction scoring.
  Effort:  M-L (human: ~4 days / CC: ~3 hrs)
  Risk:    Medium — requires git activity per session; not all sessions touch git
  Pros:    Zero user discipline. Objective data. No AI self-rating bias.
  Cons:    Can't capture satisfaction or rework (those are inherently subjective).
  Reuses:  Same backend. Git diff analysis is additive.
```

**RECOMMENDATION: Approach A** is the plan. Auto-decided (Principle 6 - bias toward action). But Approach B and C identify gaps worth cherry-picking:
- B: Make local mode the default, remote opt-in (TASTE DECISION #1)
- C: Add git-based objective signals alongside the subjective ones (TASTE DECISION #2)

### 0D. SELECTIVE EXPANSION — Cherry-pick candidates

Expansion candidates identified (auto-decided):
- **DEFERRED**: Real-time dashboard via SSE. No websocket but SSE is simpler. Interesting but out of scope for v1.
- **DEFERRED**: Export to CSV/JSON. Simple GET endpoint. Low effort.
- **DEFERRED**: Per-user personal dashboard view (filtered by user_hash). Adds GET /api/sessions?user_hash= already in the API — just need a UI for it.
- **ACCEPTED (auto)**: Add `DELETE /api/sessions/{id}` endpoint. 10 lines. Enables correcting bad data. Boil the lake. [Decision #10]
- **ACCEPTED (auto)**: Add `CCTRACKER_DEBUG=1` env var that logs hook activity to `~/.cctracker/debug.log`. 5 lines. Critical for DX. [Decision #11]
- **ACCEPTED (auto)**: Add rate limiting middleware. One import. [Decision #12]

### 0E. Temporal Interrogation

```
HOUR 1 (setup/foundations):
  - Which platform am I deploying the backend to? (no Dockerfile, no deploy config)
  - Decision: local mode first, or remote-first?

HOUR 2-3 (core hook logic):
  - How do I handle concurrent Claude Code windows? (single current.json breaks)
  - sha256sum vs shasum -a 256 on macOS?
  - What if python3 isn't available?

HOUR 4-5 (integration):
  - The Stop hook fires — but did the user run /track? Race condition between
    Claude writing classification.json and the hook reading it.
  - Session-end.sh: shell variables interpolated into Python code = injection vector.

HOUR 6+ (polish):
  - Dashboard with 0 sessions: what renders?
  - "Is it worth it?" with 3 sessions: garbage verdict?
  - What does the user see when the backend is down?
```

### Section 1: Architecture Review

```
ARCHITECTURE DIAGRAM:

  Claude Code Process           cctracker Backend (Go+Chi)
  ────────────────────────      ──────────────────────────────
  Start hook fires              POST /api/sessions
       │                               │
       ▼                               ▼
  ~/.cctracker/                  SQLite (cctracker.db)
    current.json  ◄──────┐            │
       │                 │       GET /api/stats
  [Claude session]       │       GET /api/stats/plugins
       │              session-       │
  /track invoked      end.sh         ▼
       │                │      Embedded HTML Dashboard
       ▼                ���      (index.html via go:embed)
  classification.json──┘
  (written by Claude)
```

**P0 CRITICAL: Single shared state file — concurrent session corruption.**
`~/.cctracker/current.json` is a single file. Two Claude Code windows = second start overwrites the first. The Stop hook for window 1 will read window 2's data or find a file mid-write. Fix: `~/.cctracker/sessions/${SESSION_ID}.json` per session, cleaned up after posting. [AUTO-DECIDED, Decision #1]

**P0 CRITICAL: Shell injection in session-end.sh.**
`$USER_HASH`, `$MODEL`, `$TASK_TYPE`, `$OUTCOME`, `$PLUGINS` are interpolated directly into a Python heredoc string. A hostname with a single quote or newline corrupts or injects. Fix: pass as environment variables, reference via `os.environ` inside the Python block. [AUTO-DECIDED, Decision #2]

**P1: sha256sum not portable to macOS.**
`sha256sum` is GNU coreutils only. macOS uses `shasum -a 256`. Fix: `echo -n "$(hostname)$(whoami)" | openssl dgst -sha256 | awk '{print $2}' | cut -c1-12`. Works on both. [AUTO-DECIDED, Decision #3]

**P1: CCTRACKER_BACKEND default is a live placeholder.**
`CCTRACKER_BACKEND="${CCTRACKER_BACKEND:-https://your-server.com}"` — if unset, silently fires at a real domain. Fix: validate at hook time; exit 0 with a warning written to `~/.cctracker/errors.log` if unset. [AUTO-DECIDED, Decision #4]

**P2: No rate limiting on POST /api/sessions.**
Public endpoint. Anyone can flood the DB. Go-chi has middleware for this. Fix: per-IP token bucket, 10 req/min. [AUTO-DECIDED, Decision #12]

**P2: No WAL mode for SQLite.**
Default SQLite journal mode serializes writes. Under any concurrent load (even 2 sessions POSTing at shutdown), writes queue. Fix: add `PRAGMA journal_mode=WAL` on DB init. [AUTO-DECIDED, Decision #5]

**Architecture verdict:** Core design is sound but the concurrent session state problem and shell injection are P0 landmines that will corrupt data silently.

### Section 2: Error & Rescue Map

```
CODEPATH               | WHAT CAN GO WRONG            | RESCUED?
───────────────────────|------------------------------|──────────
session-start.sh       | python3 not available        | NO ← GAP
                       | ~/.cctracker disk full       | NO ← GAP
                       | stdin JSON malformed         | partial (||echo)
session-end.sh         | classification.json missing  | YES (uses defaults)
                       | CCTRACKER_BACKEND unset      | NO ← P1 GAP
                       | Backend unreachable           | YES (try/except pass)
                       | duration_mins <= 0            | NO ← GAP (POST rejected)
POST /api/sessions     | Validation failure           | YES (400 JSON)
                       | DB write fails               | NO ← GAP (500)
GET /api/stats         | DB read fails                | NO ← GAP (500)
Dashboard fetch        | Backend down                 | NO ← GAP (blank page)
```

**Key gaps:** python3 dependency in hooks, CCTRACKER_BACKEND validation, dashboard error state, DB error handling in handlers. [AUTO-DECIDED fixes: Decision #4, #6, #7]

### Section 3: Security & Threat Model

| Threat | Likelihood | Impact | Mitigated? |
|--------|-----------|--------|-----------|
| POST spam / data poisoning | High (public endpoint) | Medium (corrupts stats) | NO → add rate limiting |
| Shell injection via hostname/username | Low (local execution) | High (arbitrary code) | NO → fix heredoc |
| User deanonymization via hash | Medium (guessable) | Low (pseudonymous) | Partial — document |
| SQLite file access | Low (local only) | Low | N/A |
| Dashboard XSS (if user data rendered) | Low (aggregated only) | Medium | Verify in implementation |

**Auto-decided:** Add rate limiting. Fix heredoc injection. Document hash pseudonymity in README.

### Section 4: Data Flow & Interaction Edge Cases

```
START HOOK:
  stdin (JSON) ──▶ python3 parse ──▶ MODEL extracted ──▶ current.json written
        │                │
        ▼                ▼
  [malformed?]    [python3 missing?]
  → MODEL="unknown"    → whole hook fails silently

END HOOK:
  current.json ──▶ parse ──▶ duration calc ──▶ POST
        │                         │
        ▼                         ▼
  [missing?] → exit 0      [negative?] → POST rejected silently
```

**Edge cases:**
- User kills Claude Code (SIGKILL): Stop hook may not fire → session lost. Acceptable, documented.
- Two sessions end simultaneously: concurrent writes to the (now per-session) state files. Safe with per-file approach.
- Backend timeout: Python `timeout=5` handles this. Good.
- Duration > 24 hours: User left session open overnight. `duration_mins` will be ~480. Probably fine but worth noting in validation.

### Section 5: Code Quality Review

**SKILL.md auto-trigger heuristic must be removed or gated.**
"Detects conversation is wrapping up" via phrases like "done", "thanks", "ship it" will fire false positives constantly — these phrases appear mid-session. Both Eng and DX subagents flagged this. The plan's degradation strategy (defaults if no classification.json) is fine; the heuristic is not. Remove it. Keep only explicit `/track`. [AUTO-DECIDED, Decision #8]

**python3 dependency in hooks is fragile.**
Both hooks use python3 for JSON parsing and UUID generation. Better: `uuidgen` (available on both Linux and macOS) for UUIDs; `jq` if available, with a fallback for JSON; shell builtins for math. Reduces dependencies. [TASTE DECISION #3 — jq vs python3]

**DRY: hooks read classification.json with 5 separate python3 invocations.**
Reads each field separately. Fix: one python3 call that outputs all fields as shell-assignable vars. [AUTO-DECIDED, Decision #9]

### Section 6: Test Review

```
NEW CODEPATHS TO TEST:
  - session-start.sh: creates ~/.cctracker/sessions/${ID}.json correctly
  - session-start.sh: handles malformed stdin gracefully
  - session-end.sh: reads session file, calculates duration, POSTs
  - session-end.sh: handles missing session file (exits 0)
  - session-end.sh: handles CCTRACKER_BACKEND unset (logs, exits 0)
  - POST /api/sessions: all validation rules (each field)
  - POST /api/sessions: duplicate ID handling
  - GET /api/stats: aggregation correctness
  - GET /api/stats/plugins: sorting, completion rate calculation
  - Dashboard: empty state, error state, data rendering
  - install.sh: idempotency on second run
  - install.sh: settings.json merge correctness
```

**USER CHALLENGE #1: The "no tests" constraint.**
The plan explicitly says "No tests (out of scope for now — ship working code first)." Both the Eng subagent and primary review independently flagged this as risky for a data pipeline where all failures are silent. The hooks and settings.json patching logic are exactly the code most likely to corrupt user config.

Minimum viable test coverage: shell tests for session-start.sh and session-end.sh (using `bats` or just `bash -x` + assertions), and Go handler tests for POST validation and GET stats. ~90 lines total. With CC, this is 20 minutes.

This is a USER CHALLENGE — the plan explicitly defers tests and both models disagree. See Final Gate.

### Section 7: Performance Review

- SQLite is appropriate for this workload. Queries are simple aggregates.
- `idx_plugins` on a TEXT field with comma-separated values is weak for the plugin stats query. The plugins column stores "gstack,ruflo" as a string; GROUP BY on it will never split combos. This is by design (the plan compares combos), but it means "gstack alone" and "gstack+ruflo" are different rows, which is correct. No N+1 risk.
- `avg()` over all sessions for stats could be slow at 100k+ rows. Add a materialized view or periodic rollup if this scales. Not a v1 concern.
- Add `PRAGMA journal_mode=WAL` at startup. [Decision #5]

### Section 8: Observability & Debuggability

**Critical gap: everything fails silently by design.**
This is the right production policy for hooks (never block the user) but creates a debugging nightmare. A developer who installs cctracker and sees no data in the dashboard has no idea why.

Fix: `CCTRACKER_DEBUG=1` → write to `~/.cctracker/debug.log`:
- Hook start/end events
- POST success/failure with status code
- Any validation errors

[AUTO-DECIDED, Decision #11]

### Section 9: Deployment & Rollout

**P1: No deployment path for the backend.**
The plan says "No Docker file (out of scope for now)" and defers to README. But the README is the last thing built (Section 4, step 7). This means the install script succeeds, the user has no backend to connect to, and the skill silently does nothing.

Minimum: add one `go build -o cctracker-server .` command to the README with a "run locally" path. Even `go run main.go` is enough to unblock.

The plan's Section 2.6 defines `PORT` and `DB_PATH` env vars — good. But there's no documented "here's how you try this in 30 seconds" path.

[TASTE DECISION #1: local-default vs remote-first]

### Section 10: Long-Term Trajectory

- Technical debt introduced: fragile hooks, no tests, silent failures. High debt.
- Path dependency: the `plugins` TEXT field as comma-separated string is a one-way door once there's production data. If you ever want to query "all sessions that used gstack, regardless of what else was used", you can't.
- Reversibility: 2/5 — the data schema, once populated, is hard to change.
- Knowledge concentration: no existing code to read. A new contributor needs to understand hook lifecycle, Claude Code SKILL.md system, Go Chi, and SQLite to contribute to any layer.
- **The 1-year question:** "Why is satisfaction always 3?" will be the first support question. The default values tell the real story about data quality.

### Section 11: Design & UX Review

**Missing states (CRITICAL):**
No specification for:
- 0 sessions: dashboard is blank. Show "No sessions yet. Run `/track` to start."
- 1-4 sessions: verdict section invisible without explanation.
- Backend down: fetch returns 500, page shows nothing. Show error banner.
- Loading: no spinner, no skeleton.

[AUTO-DECIDED, Decision #6]

**"Is it worth it?" verdict threshold is too low.**
5 sessions with self-reported scores produces noise, not signal. Raise to 20 sessions minimum. Or suppress the verdict entirely for v1 and show a progress bar: "12/20 sessions to unlock verdict." [AUTO-DECIDED, Decision #7]

**Information hierarchy is inverted.**
Hero row leads with "Total Sessions" — a vanity metric. The most actionable content (plugin comparison verdict) is at the bottom. Invert: verdict first, aggregate stats last. [AUTO-DECIDED, Decision #13]

**avg_satisfaction without distribution context is misleading.**
"3.8" means nothing without spread. Add a simple 5-star visual or min/max/avg display. [AUTO-DECIDED, Decision #14]

**Font: system-ui primary, monospace only for numbers.**
Keep dark theme. Use `system-ui` for labels/prose. Apply `font-variant-numeric: tabular-nums` on numbers. The plan already lists `system-ui` as a fallback — promote it. [AUTO-DECIDED, Decision #15]

---

## CEO DUAL VOICES — CONSENSUS TABLE

```
CEO DUAL VOICES — CONSENSUS TABLE:
═══════════════════════════════════��═══════════════════════════════
  Dimension                              Claude   Subagent   Consensus
  ─────���────────────────────────────────  ──────   ────────   ──────────
  1. Premises valid?                      Partly    NO        DISAGREE
  2. Right problem to solve?              Yes       Framing↑  DISAGREE
  3. Scope calibration correct?           Over-eng  Over-eng  CONFIRMED
  4. Alternatives sufficiently explored?  No        No        CONFIRMED
  5. Competitive/market risks covered?    Missing   Missing   CONFIRMED
  6. 6-month trajectory sound?            Risky     Bad data  CONFIRMED
══════════════════���════════════════════════════════���═══════════════
DISAGREE items → surfaced at final gate as USER CHALLENGES.
```

**Phase 1 complete.** Subagent: 6 concerns. Primary review: 15 issues.
Consensus: 4/6 confirmed. 2 disagreements surfaced at gate.

---

## ENG DUAL VOICES — CONSENSUS TABLE

```
ENG DUAL VOICES — CONSENSUS TABLE:
════════════════════════════════════════════════���══════════════════
  Dimension                              Claude   Subagent   Consensus
  ───────────────────────────────────��──  ──────   ────────   ──────────
  1. Architecture sound?                  No       P0 race   CONFIRMED NO
  2. Test coverage sufficient?            No       P2 risky  CONFIRMED NO
  3. Performance risks addressed?         Mostly   N/A       N/A
  4. Security threats covered?            No       P1 gap    CONFIRMED NO
  5. Error paths handled?                 No       P0 inject CONFIRMED (worse than thought)
  6. Deployment risk manageable?          N/A      N/A       N/A
═══════════════════════���════════════════════════════���══════════════
```

**Phase 3 complete.** Subagent: 6 findings (2xP0, 2xP1, 2xP2). Consensus: 4/6 confirmed.

---

## DESIGN DUAL VOICES — CONSENSUS TABLE

```
DESIGN DUAL VOICES — CONSENSUS TABLE:
═══���════════��══════════════════════════════════���═══════════════════
  Dimension                              Claude   Subagent   Consensus
  ──────────────��───────────────────────  ──���───   ────────   ───��──────
  1. Missing states specified?            No       CRITICAL  CONFIRMED NO
  2. "Is it worth it?" verdict reliable?  No       HIGH      CONFIRMED NO
  3. Information hierarchy correct?       Inverted MEDIUM    CONFIRMED
  4. avg_satisfaction meaningful?         No ctx   HIGH      CONFIRMED
  5. Plugin table sparse data?            Gap      MEDIUM    CONFIRMED
  6. Backend error state?                 Missing  MEDIUM    CONFIRMED
═══════════════════════════���════════════════════════════��══════════
```

---

## DX DUAL VOICES — CONSENSUS TABLE

```
DX DUAL VOICES — CONSENSUS TABLE:
════════════════════════════════════════════���══════════════════════
  Dimension                              Claude   Subagent   Consensus
  ─────────────��────────────────────────  ──────   ────────   ──────────
  1. Getting started < 5 min?             NO       NO        CONFIRMED BAD
  2. CCTRACKER_BACKEND handling?          Missing  CRITICAL  CONFIRMED MISSING
  3. Error messages actionable?           No       Critical  CONFIRMED NO
  4. Docs/deploy path clear?              No       High      CONFIRMED NO
  5. Auto-trigger heuristic reliable?     No       HIGH      CONFIRMED NO
  6. Dev environment friction-free?       No       No        CONFIRMED NO
══════��═══════════════════════════���══════════════════════════���═════
TTHW: ~10+ min (Red Flag tier). Target: < 5 min.
```

---

## Decision Audit Trail

| # | Phase | Decision | Classification | Principle | Rationale | Rejected |
|---|-------|----------|----------------|-----------|-----------|----------|
| 1 | Eng | Per-session state files instead of shared current.json | Mechanical | P1 (completeness) | Prevents concurrent session data corruption | Single shared file |
| 2 | Eng | Fix shell injection: pass vars as env, use os.environ in Python | Mechanical | P1 (completeness) | P0 security fix — no real alternative | String interpolation |
| 3 | Eng | Use openssl dgst for user hash (portable) | Mechanical | P1 (completeness) | sha256sum fails on macOS; plan claims macOS support | sha256sum |
| 4 | Eng | Validate CCTRACKER_BACKEND at hook time, log error if unset | Mechanical | P1 (completeness) | Placeholder URL silently swallows all data | Silent pass |
| 5 | Eng | Add PRAGMA journal_mode=WAL on DB init | Mechanical | P3 (pragmatic) | Concurrent reads degrade without WAL; one line | Default journal |
| 6 | Design | Add empty/loading/error states to dashboard | Mechanical | P1 (completeness) | Blank page on 0 sessions = broken UX | No states |
| 7 | Design | Raise verdict threshold to 20 sessions minimum | Mechanical | P3 (pragmatic) | 5 sessions insufficient for statistical signal | 5 session threshold |
| 8 | Code | Remove SKILL.md auto-trigger heuristic | Mechanical | P5 (explicit over clever) | "done" fires mid-session constantly; false positives | Auto-detect |
| 9 | Code | DRY: single python3 call in session-end.sh for all fields | Mechanical | P4 (DRY) | 5 separate python3 invocations for one JSON file | 5x calls |
| 10 | API | Add DELETE /api/sessions/{id} endpoint | Mechanical | P2 (boil lake) | Enables correcting bad data; 10 lines | No delete |
| 11 | DX | Add CCTRACKER_DEBUG env var → debug.log | Mechanical | P1 (completeness) | Silent failures make debugging impossible | All silent |
| 12 | Security | Add per-IP rate limiting on POST /api/sessions | Mechanical | P1 (completeness) | Public endpoint; no throttle = trivial spam | No rate limit |
| 13 | Design | Invert dashboard layout: verdict first, stats last | Mechanical | P5 (explicit) | User's real question is in the verdict section | Stats-first |
| 14 | Design | Add distribution context to avg_satisfaction display | Mechanical | P1 (completeness) | Single number without spread is misleading | Single number |
| 15 | Design | Promote system-ui to primary font; tabular-nums for numbers | Mechanical | P5 (explicit) | Monospace body text impairs data scanning | All monospace |

---

## NOT in scope (auto-deferred)

- Real-time dashboard via SSE/websocket (out of scope per plan — affirmed)
- CSV/JSON export endpoint
- Per-user personal dashboard view
- Dockerfile / deploy infrastructure (explicitly deferred by plan)
- Full test suite (USER CHALLENGE — see gate)
- Automatic classification via git diff analysis (Approach C — deferred to v2)
- User accounts or authentication

## What Already Exists

- Nothing — greenfield. All sub-problems are net-new.
- Go Chi, modernc.org/sqlite, google/uuid are Layer 1 (tried-and-true) dependencies. Good choices.
- Claude Code hooks system is the integration point. Correctly identified.

## Dream State Delta

This plan gets us from "nothing" to "noisy but working tracker." The gap to the 12-month ideal is:
1. Automatic classification (replace manual /track with git diff analysis)
2. Personal dashboard view (filter by user_hash)
3. Data quality improvements (objective signals alongside subjective ones)

The v1 plan is defensible as a learning instrument. But expect the satisfaction data to be unreliable until classification is automatic.

---

## GSTACK REVIEW REPORT

| Review | Via | Runs | Status | Key Findings |
|--------|-----|------|--------|--------------|
| CEO Review | autoplan subagent | 1 | issues_open | Premises weak; data quality problem; backend-first blocks adoption |
| Design Review | autoplan subagent | 1 | issues_open | 6 findings: missing states (critical), verdict threshold, hierarchy |
| Eng Review | autoplan subagent | 1 | issues_open | 2xP0 (race condition, shell injection), 2xP1, 2xP2 |
| DX Review | autoplan subagent | 1 | issues_open | TTHW red flag; placeholder URL critical; silent errors |
| Codex Review | unavailable | 0 | — | Codex not installed |

**VERDICT:** ISSUES_OPEN — 2 USER CHALLENGES + 15 auto-decided fixes + 3 taste decisions. See Final Gate below.

