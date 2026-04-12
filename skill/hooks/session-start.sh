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
SESSION_FILE=~/.cctracker/sessions/${SESSION_ID}.json
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

# Store session ID for this shell process so session-end.sh can find it
echo "$SESSION_ID" > ~/.cctracker/sessions/.pid-$$.id

[ -n "${CCTRACKER_DEBUG:-}" ] && echo "$(date): cctracker start — session $SESSION_ID model=$MODEL plugins=$PLUGINS" >> ~/.cctracker/debug.log

exit 0
