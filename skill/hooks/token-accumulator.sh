#!/usr/bin/env bash
# hooks/token-accumulator.sh
# PostToolUse hook — accumulates token usage from each API response
set -euo pipefail

SESSION_ID_FILE=~/.cctracker/sessions/.current_id
[ ! -f "$SESSION_ID_FILE" ] && exit 0

SESSION_ID=$(cat "$SESSION_ID_FILE")
TOKENS_FILE=~/.cctracker/sessions/${SESSION_ID}.tokens

STDIN=$(cat)

if command -v jq >/dev/null 2>&1; then
    INPUT=$(echo "$STDIN"  | jq -r '.usage.input_tokens              // 0' 2>/dev/null || echo 0)
    OUTPUT=$(echo "$STDIN" | jq -r '.usage.output_tokens             // 0' 2>/dev/null || echo 0)
    CR=$(echo "$STDIN"     | jq -r '.usage.cache_read_input_tokens   // 0' 2>/dev/null || echo 0)
    CC=$(echo "$STDIN"     | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || echo 0)
else
    _U=$(echo "$STDIN" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    u = d.get('usage', {})
    print(u.get('input_tokens', 0))
    print(u.get('output_tokens', 0))
    print(u.get('cache_read_input_tokens', 0))
    print(u.get('cache_creation_input_tokens', 0))
except Exception:
    print(0); print(0); print(0); print(0)
" 2>/dev/null || printf "0\n0\n0\n0")
    INPUT=$(echo "$_U"  | sed -n '1p')
    OUTPUT=$(echo "$_U" | sed -n '2p')
    CR=$(echo "$_U"     | sed -n '3p')
    CC=$(echo "$_U"     | sed -n '4p')
fi

# Skip if no tokens were reported (hook payload had no usage field)
[ "$INPUT" = "0" ] && [ "$OUTPUT" = "0" ] && exit 0

echo "$INPUT $OUTPUT $CR $CC" >> "$TOKENS_FILE"

[ -n "${CCTRACKER_DEBUG:-}" ] && \
    echo "$(date): cctracker tokens — in=$INPUT out=$OUTPUT cr=$CR cc=$CC" >> ~/.cctracker/debug.log

exit 0
