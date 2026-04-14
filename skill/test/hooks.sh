#!/usr/bin/env bash
# skill/test/hooks.sh — integration tests for cctracker hooks
# Usage: bash skill/test/hooks.sh
# Requires: python3, openssl (same deps as the hooks themselves)
set -euo pipefail

PASS=0
FAIL=0
HOOKS_DIR="$(cd "$(dirname "$0")/../hooks" && pwd)"
TMPDIR_BASE=$(mktemp -d)
MOCK_PID=""

cleanup() {
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
    rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

# ── helpers ─────────────────────────────────────────────────────────────────

_pass() { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
_fail() { echo "  FAIL: $1"; FAIL=$(( FAIL + 1 )); }

# ── mock HTTP server ─────────────────────────────────────────────────────────

MOCK_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
MOCK_LOG="$TMPDIR_BASE/mock.log"
MOCK_SCRIPT="$TMPDIR_BASE/mock_server.py"

cat > "$MOCK_SCRIPT" << PYEOF
import http.server, sys

port = int(sys.argv[1])
log  = sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        with open(log, "a") as f:
            f.write(body.decode() + "\n")
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a): pass

with http.server.HTTPServer(("127.0.0.1", port), Handler) as s:
    s.serve_forever()
PYEOF

python3 "$MOCK_SCRIPT" "$MOCK_PORT" "$MOCK_LOG" &
MOCK_PID=$!
# Wait for server to be ready
for _i in 1 2 3 4 5; do
    python3 -c "import socket; s=socket.socket(); s.connect(('127.0.0.1',$MOCK_PORT)); s.close()" 2>/dev/null && break
    sleep 0.2
done

export CCTRACKER_BACKEND="http://127.0.0.1:$MOCK_PORT"

# Override HOME so tests don't touch ~/.cctracker
export HOME="$TMPDIR_BASE"
mkdir -p "$HOME/.cctracker/sessions" "$HOME/.cctracker/hooks"
cp "$HOOKS_DIR/session-finalize.sh" "$HOME/.cctracker/hooks/"
cp "$HOOKS_DIR/session-end.sh"      "$HOME/.cctracker/hooks/"
cp "$HOOKS_DIR/token-accumulator.sh" "$HOME/.cctracker/hooks/"
chmod +x "$HOME/.cctracker/hooks/"*.sh

# ── helper: create a valid session file ─────────────────────────────────────

make_session() {
    local uuid="$1"
    local start_ts="${2:-$(( $(date +%s) - 300 ))}"  # 5 min ago default
    python3 -c "
import json
d = {'session_id': '$uuid', 'start_ts': $start_ts, 'model': 'claude-sonnet-4-6', 'plugins': 'none'}
path = '$HOME/.cctracker/sessions/${uuid}.json'
with open(path, 'w') as f:
    json.dump(d, f)
"
    echo "$uuid" > "$HOME/.cctracker/sessions/.current_id"
}

post_count() {
    [ -f "$MOCK_LOG" ] && wc -l < "$MOCK_LOG" | tr -d ' ' || echo 0
}

# ── TEST 1: lockfile dedup ───────────────────────────────────────────────────

echo "TEST 1: lockfile dedup — only 1 POST for 2 concurrent finalize calls"
UUID1=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
make_session "$UUID1"
BEFORE=$(post_count)
bash "$HOME/.cctracker/hooks/session-finalize.sh" "$UUID1" "test1-first"  &
JOB1=$!
bash "$HOME/.cctracker/hooks/session-finalize.sh" "$UUID1" "test1-second" &
JOB2=$!
wait $JOB1 $JOB2
sleep 0.3
AFTER=$(post_count)
POSTED=$(( AFTER - BEFORE ))
if [ "$POSTED" -eq 1 ]; then
    _pass "lockfile dedup: exactly 1 POST ($POSTED)"
else
    _fail "lockfile dedup: expected 1 POST, got $POSTED"
fi

# ── TEST 2: duration guard (zero — start_ts is now) ─────────────────────────

echo "TEST 2: duration guard — skip when start_ts is now (duration=0)"
UUID2=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
make_session "$UUID2" "$(date +%s)"
BEFORE=$(post_count)
bash "$HOME/.cctracker/hooks/session-finalize.sh" "$UUID2" "test2"
AFTER=$(post_count)
POSTED=$(( AFTER - BEFORE ))
if [ "$POSTED" -eq 0 ]; then
    _pass "duration guard zero: 0 POSTs as expected"
else
    _fail "duration guard zero: expected 0 POSTs, got $POSTED"
fi
if [ ! -f "$HOME/.cctracker/sessions/${UUID2}.posted" ]; then
    _pass "duration guard zero: lockfile cleaned up"
else
    _fail "duration guard zero: lockfile NOT cleaned up"
fi

# ── TEST 3: duration guard overflow (start_ts=0) ────────────────────────────

echo "TEST 3: duration guard — skip when start_ts=0 (duration > 1440)"
UUID3=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
make_session "$UUID3" "0"
BEFORE=$(post_count)
bash "$HOME/.cctracker/hooks/session-finalize.sh" "$UUID3" "test3"
AFTER=$(post_count)
POSTED=$(( AFTER - BEFORE ))
if [ "$POSTED" -eq 0 ]; then
    _pass "duration guard overflow: 0 POSTs as expected"
else
    _fail "duration guard overflow: expected 0 POSTs, got $POSTED"
fi

# ── TEST 4: session file missing ─────────────────────────────────────────────

echo "TEST 4: missing session file — clean exit, no POST"
UUID4=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
BEFORE=$(post_count)
bash "$HOME/.cctracker/hooks/session-finalize.sh" "$UUID4" "test4"
AFTER=$(post_count)
POSTED=$(( AFTER - BEFORE ))
if [ "$POSTED" -eq 0 ]; then
    _pass "missing session file: 0 POSTs as expected"
else
    _fail "missing session file: expected 0 POSTs, got $POSTED"
fi

# ── TEST 5: session-end.sh is no-op in always-on mode ────────────────────────

echo "TEST 5: session-end.sh exits immediately when CCTRACKER_ENABLED=1"
UUID5=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
make_session "$UUID5"
BEFORE=$(post_count)
CCTRACKER_ENABLED=1 bash "$HOME/.cctracker/hooks/session-end.sh"
AFTER=$(post_count)
POSTED=$(( AFTER - BEFORE ))
if [ "$POSTED" -eq 0 ]; then
    _pass "session-end.sh no-op: 0 POSTs in always-on mode"
else
    _fail "session-end.sh no-op: expected 0 POSTs, got $POSTED"
fi

# ── TEST 6: token-accumulator reads .current_id ──────────────────────────────

echo "TEST 6: token-accumulator reads .current_id (not .pid-\$\$.id)"
UUID6=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
echo "$UUID6" > "$HOME/.cctracker/sessions/.current_id"
TOKENS_FILE="$HOME/.cctracker/sessions/${UUID6}.tokens"
FAKE_STDIN='{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10,"cache_creation_input_tokens":5}}'
echo "$FAKE_STDIN" | bash "$HOME/.cctracker/hooks/token-accumulator.sh"
if [ -f "$TOKENS_FILE" ] && grep -q "100 50 10 5" "$TOKENS_FILE"; then
    _pass "token-accumulator: tokens written to correct file"
else
    _fail "token-accumulator: tokens file missing or wrong content ($(cat "$TOKENS_FILE" 2>/dev/null || echo 'missing'))"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
