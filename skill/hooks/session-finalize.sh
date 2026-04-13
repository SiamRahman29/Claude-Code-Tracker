#!/usr/bin/env bash
# hooks/session-finalize.sh <session_id> [source]
# Finalizes a session: computes duration + cost, POSTs once, cleans up.
# Called by session-watchdog.sh (primary) and session-end.sh (fallback).
# Dedup: atomic lockfile prevents double-POST across concurrent callers.
set -euo pipefail

SESSION_ID="${1:-}"
SOURCE="${2:-unknown}"

DEBUG_LOG=~/.cctracker/debug.log
ERR_LOG=~/.cctracker/errors.log

_log_debug() { if [ -n "${CCTRACKER_DEBUG:-}" ]; then echo "$(date): cctracker finalize[$SOURCE]: $*" >> "$DEBUG_LOG"; fi; }
_log_err()   { echo "$(date): cctracker finalize[$SOURCE] ERROR: $*" >> "$ERR_LOG"; }

[ -z "$SESSION_ID" ] && exit 0

# Validate backend URL
if [ -z "${CCTRACKER_BACKEND:-}" ] || [ "${CCTRACKER_BACKEND}" = "https://your-server.com" ]; then
    _log_err "CCTRACKER_BACKEND not set or still placeholder — skipping POST."
    exit 0
fi

# Atomic lockfile: only one caller proceeds (set -C disables clobber in subshell)
LOCK_FILE=~/.cctracker/sessions/${SESSION_ID}.posted
if ! ( set -C; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
    _log_debug "Already finalized (lockfile exists) — skipping"
    exit 0
fi

SESSION_FILE=~/.cctracker/sessions/${SESSION_ID}.json
if [ ! -f "$SESSION_FILE" ]; then
    _log_err "Session file missing: $SESSION_FILE"
    exit 0
fi

# Parse session file (jq preferred, python3 fallback)
if command -v jq >/dev/null 2>&1; then
    START_TS=$(jq -r '.start_ts' "$SESSION_FILE")
    MODEL=$(jq -r '.model' "$SESSION_FILE")
    PLUGINS=$(jq -r '.plugins' "$SESSION_FILE")
else
    _PARSED=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('start_ts', 0))
    print(d.get('model', 'unknown'))
    print(d.get('plugins', 'none'))
except Exception:
    print(0); print('unknown'); print('none')
" "$SESSION_FILE" 2>/dev/null || printf "0\nunknown\nnone")
    START_TS=$(echo "$_PARSED" | sed -n '1p')
    MODEL=$(echo "$_PARSED"   | sed -n '2p')
    PLUGINS=$(echo "$_PARSED" | sed -n '3p')
fi

END_TS=$(date +%s)
DURATION=$(( (END_TS - START_TS) / 60 ))

# Guard: skip nonsensical durations
if [ "$DURATION" -le 0 ]; then
    _log_debug "Duration <= 0, skipping"
    rm -f "$LOCK_FILE"
    exit 0
fi
if [ "$DURATION" -gt 1440 ]; then
    _log_debug "Duration > 24h ($DURATION min), likely bad start_ts — skipping"
    rm -f "$SESSION_FILE" "$LOCK_FILE" \
        ~/.cctracker/sessions/${SESSION_ID}.tokens \
        ~/.cctracker/sessions/${SESSION_ID}.watchdog_pid \
        ~/.cctracker/sessions/.current_id 2>/dev/null || true
    exit 0
fi

# Compute anonymous user hash (portable: works on macOS + Linux + WSL)
_HOST=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo "localhost")
USER_HASH=$(echo -n "${_HOST}$(whoami)" | openssl dgst -sha256 2>/dev/null | awk '{print $2}' | cut -c1-12)
[ -z "$USER_HASH" ] && USER_HASH="fallbackuser"

# Compute token cost from accumulated token data
TOKENS_FILE=~/.cctracker/sessions/${SESSION_ID}.tokens
export _CC_TOKENS_FILE="$TOKENS_FILE"
export _CC_MODEL_FOR_COST="$MODEL"

TOKEN_COST=$(python3 - <<'PYEOF'
import os

tokens_file = os.environ.get('_CC_TOKENS_FILE', '')
model = os.environ.get('_CC_MODEL_FOR_COST', 'unknown').lower()

# Pricing: (input, output, cache_read, cache_create) per million tokens
PRICING = {
    'claude-opus-4-6':        (15.00, 75.00, 1.500, 18.750),
    'claude-sonnet-4-6':      ( 3.00, 15.00, 0.300,  3.750),
    'claude-haiku-4-5':       ( 0.80,  4.00, 0.080,  1.000),
    'claude-opus-4':          (15.00, 75.00, 1.500, 18.750),
    'claude-sonnet-4':        ( 3.00, 15.00, 0.300,  3.750),
    'claude-haiku-4':         ( 0.80,  4.00, 0.080,  1.000),
    'claude-opus-3-7':        (15.00, 75.00, 1.500, 18.750),
    'claude-sonnet-3-7':      ( 3.00, 15.00, 0.300,  3.750),
    'claude-haiku-3-5':       ( 0.80,  4.00, 0.080,  1.000),
}

def get_pricing(m):
    if m in PRICING:
        return PRICING[m]
    for key, val in PRICING.items():
        if m.startswith(key):
            return val
    return PRICING['claude-sonnet-4-6']

total_in = total_out = total_cr = total_cc = 0
try:
    with open(tokens_file) as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) >= 2:
                total_in  += int(parts[0])
                total_out += int(parts[1])
            if len(parts) >= 4:
                total_cr += int(parts[2])
                total_cc += int(parts[3])
except Exception:
    pass

p = get_pricing(model)
cost = (total_in * p[0] + total_out * p[1] + total_cr * p[2] + total_cc * p[3]) / 1_000_000
print(f"{cost:.4f}")
PYEOF
)
TOKEN_COST="${TOKEN_COST:-0}"

# Always-on mode: use hardcoded defaults (no /track classification required)
TASK_TYPE="other"
OUTCOME="complete"
REWORK_SCORE=1
SATISFACTION=3

_log_debug "Posting session $SESSION_ID: duration=${DURATION}m cost=\$$TOKEN_COST source=$SOURCE"

# POST to backend (fire and forget — never block the user)
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
export _CC_BACKEND="$CCTRACKER_BACKEND"

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

# Cleanup — keep .posted lockfile (dedup gate for subsequent Stop hook turns)
rm -f "$SESSION_FILE" \
      ~/.cctracker/sessions/${SESSION_ID}.tokens \
      ~/.cctracker/sessions/${SESSION_ID}.watchdog_pid \
      ~/.cctracker/sessions/.current_id 2>/dev/null || true

exit 0
