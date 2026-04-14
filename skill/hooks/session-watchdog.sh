#!/usr/bin/env bash
# hooks/session-watchdog.sh <session_id> <claude_pid>
# Background daemon started by session-start.sh.
# Polls the Claude Code PID; fires session-finalize.sh when the process exits.
# Handles any exit method: /exit, Ctrl+C, terminal close, crash.
set -euo pipefail

SESSION_ID="${1:-}"
CLAUDE_PID="${2:-}"

[ -z "$SESSION_ID" ] && exit 1
[ -z "$CLAUDE_PID" ] && exit 1

FINALIZE=~/.cctracker/hooks/session-finalize.sh
WATCHDOG_PID_FILE=~/.cctracker/sessions/${SESSION_ID}.watchdog_pid

[ -n "${CCTRACKER_DEBUG:-}" ] && \
    echo "$(date): cctracker watchdog started — session=$SESSION_ID watching pid=$CLAUDE_PID" \
    >> ~/.cctracker/debug.log

# Poll until Claude Code exits (portable: kill -0 works on Linux, macOS, WSL)
while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    sleep 5
done

[ -n "${CCTRACKER_DEBUG:-}" ] && \
    echo "$(date): cctracker watchdog — pid=$CLAUDE_PID exited, finalizing session=$SESSION_ID" \
    >> ~/.cctracker/debug.log

# Clean up watchdog PID marker before calling finalize
rm -f "$WATCHDOG_PID_FILE" 2>/dev/null || true

# Finalize the session
[ -f "$FINALIZE" ] && bash "$FINALIZE" "$SESSION_ID" "watchdog"

exit 0
