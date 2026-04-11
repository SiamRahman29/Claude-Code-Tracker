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

# Parse session file (jq preferred, python3 fallback)
if command -v jq >/dev/null 2>&1; then
    START_TS=$(jq -r '.start_ts' "$SESSION_FILE")
    MODEL=$(jq -r '.model' "$SESSION_FILE")
    PLUGINS=$(jq -r '.plugins' "$SESSION_FILE")
else
    # Single python3 call — read all fields at once (no shell interpolation)
    _PARSED=$(python3 - <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('start_ts', 0))
    print(d.get('model', 'unknown'))
    print(d.get('plugins', 'none'))
except Exception:
    print(0)
    print('unknown')
    print('none')
PYEOF
    )
    START_TS=$(echo "$_PARSED" | sed -n '1p')
    MODEL=$(echo "$_PARSED" | sed -n '2p')
    PLUGINS=$(echo "$_PARSED" | sed -n '3p')
fi

END_TS=$(date +%s)
DURATION=$(( (END_TS - START_TS) / 60 ))

# Guard: skip nonsensical durations
[ "$DURATION" -le 0 ] && { _log_debug "Duration <= 0, skipping post"; rm -f "$SESSION_FILE" "$PID_FILE"; exit 0; }

# Compute anonymous user hash (portable: works on macOS + Linux)
USER_HASH=$(echo -n "$(hostname)$(whoami)" | openssl dgst -sha256 2>/dev/null | awk '{print $2}' | cut -c1-12)
[ -z "$USER_HASH" ] && USER_HASH="unknown"

# Read classification written by /track skill
CLASSIFICATION=~/.cctracker/classification_${SESSION_ID}.json
# Fallback to latest if session-specific not found
[ ! -f "$CLASSIFICATION" ] && CLASSIFICATION=~/.cctracker/classification_latest.json

TASK_TYPE="other"; OUTCOME="complete"; REWORK_SCORE=1; SATISFACTION=3; TOKEN_COST=0

if [ -f "$CLASSIFICATION" ]; then
    if command -v jq >/dev/null 2>&1; then
        TASK_TYPE=$(jq -r '.task_type // "other"' "$CLASSIFICATION")
        OUTCOME=$(jq -r '.outcome // "complete"' "$CLASSIFICATION")
        REWORK_SCORE=$(jq -r '.rework_score // 1' "$CLASSIFICATION")
        SATISFACTION=$(jq -r '.satisfaction // 3' "$CLASSIFICATION")
        TOKEN_COST=$(jq -r '.token_cost // 0' "$CLASSIFICATION")
    else
        # All values read from env vars — no shell interpolation into python strings
        export _CC_CLASS_FILE="$CLASSIFICATION"
        _CVALS=$(python3 - <<'PYEOF'
import json, os
try:
    d = json.load(open(os.environ['_CC_CLASS_FILE']))
    print(d.get('task_type','other'))
    print(d.get('outcome','complete'))
    print(d.get('rework_score',1))
    print(d.get('satisfaction',3))
    print(d.get('token_cost',0))
except Exception:
    print('other'); print('complete'); print(1); print(3); print(0)
PYEOF
        )
        TASK_TYPE=$(echo "$_CVALS" | sed -n '1p')
        OUTCOME=$(echo "$_CVALS" | sed -n '2p')
        REWORK_SCORE=$(echo "$_CVALS" | sed -n '3p')
        SATISFACTION=$(echo "$_CVALS" | sed -n '4p')
        TOKEN_COST=$(echo "$_CVALS" | sed -n '5p')
    fi
    rm -f "$CLASSIFICATION"
fi

_log_debug "Posting session $SESSION_ID: task=$TASK_TYPE outcome=$OUTCOME duration=${DURATION}m satisfaction=$SATISFACTION"

# POST to backend (fire and forget — never block the user)
# All shell vars passed as env vars; Python reads ONLY from os.environ (no shell injection)
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
except Exception:
    pass  # Never block the user
PYEOF

# Cleanup
rm -f "$SESSION_FILE" "$PID_FILE"
exit 0
