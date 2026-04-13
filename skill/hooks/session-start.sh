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

# Write per-session state file using Python to safely encode strings (no heredoc injection)
export _CC_SID="$SESSION_ID" _CC_TS="$START_TS" _CC_MDL="$MODEL" _CC_PLG="$PLUGINS"
python3 - <<'PYEOF'
import json, os
d = {
    "session_id": os.environ["_CC_SID"],
    "start_ts":   int(os.environ["_CC_TS"]),
    "model":      os.environ["_CC_MDL"],
    "plugins":    os.environ["_CC_PLG"],
}
with open(os.path.expanduser(f"~/.cctracker/sessions/{d['session_id']}.json"), "w") as f:
    json.dump(d, f)
PYEOF

# Write a stable pointer that session-end.sh can always find, regardless of how
# Claude Code spawns the hook subprocesses ($$ and $PPID are unreliable across
# separate hook invocations).
echo "$SESSION_ID" > ~/.cctracker/sessions/.current_id

[ -n "${CCTRACKER_DEBUG:-}" ] && echo "$(date): cctracker start — session $SESSION_ID model=$MODEL plugins=$PLUGINS" >> ~/.cctracker/debug.log || true

# Clean up stale files from old sessions (>7 days) to prevent accumulation
find ~/.cctracker/sessions/ -name "*.posted"      -mtime +7 -delete 2>/dev/null || true
find ~/.cctracker/sessions/ -name "*.watchdog_pid" -mtime +7 -delete 2>/dev/null || true

# Always-on mode: start a background watchdog that detects session end on any exit type.
# $PPID is the Claude Code process that spawned this hook — the PID to watch.
if [ "${CCTRACKER_ENABLED:-}" = "1" ]; then
    WATCHDOG=~/.cctracker/hooks/session-watchdog.sh
    if [ -f "$WATCHDOG" ]; then
        nohup bash "$WATCHDOG" "$SESSION_ID" "$PPID" > /dev/null 2>&1 &
        WATCHDOG_PID=$!
        disown "$WATCHDOG_PID" 2>/dev/null || true
        echo "$WATCHDOG_PID" > ~/.cctracker/sessions/${SESSION_ID}.watchdog_pid
        [ -n "${CCTRACKER_DEBUG:-}" ] && echo "$(date): cctracker watchdog launched — pid=$WATCHDOG_PID watching=$PPID" >> ~/.cctracker/debug.log || true
    else
        [ -n "${CCTRACKER_DEBUG:-}" ] && echo "$(date): cctracker watchdog script missing — $WATCHDOG" >> ~/.cctracker/debug.log || true
    fi
fi

exit 0
