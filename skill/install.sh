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
cp "$(dirname "$0")/SKILL.md" "$SKILL_DIR/SKILL.md"

# 3. Copy and chmod hooks
cp "$(dirname "$0")/hooks/session-start.sh"     "$HOOKS_DIR/session-start.sh"
cp "$(dirname "$0")/hooks/session-end.sh"       "$HOOKS_DIR/session-end.sh"
cp "$(dirname "$0")/hooks/token-accumulator.sh" "$HOOKS_DIR/token-accumulator.sh"
chmod +x "$HOOKS_DIR/session-start.sh"
chmod +x "$HOOKS_DIR/session-end.sh"
chmod +x "$HOOKS_DIR/token-accumulator.sh"

# 4. Patch CLAUDE.md (add @import if not already present)
IMPORT_LINE="@~/.claude/skills/cctracker/SKILL.md"
if [ -f "$CLAUDE_MD" ]; then
    grep -qF "$IMPORT_LINE" "$CLAUDE_MD" || echo "$IMPORT_LINE" >> "$CLAUDE_MD"
else
    echo "$IMPORT_LINE" > "$CLAUDE_MD"
fi

# 5. Patch settings.json hooks (safe merge via Python — no clobbering)
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
    "Start":       [{"matcher": "", "hooks": [{"type": "command", "command": f"{hooks_dir}/session-start.sh"}]}],
    "Stop":        [{"matcher": "", "hooks": [{"type": "command", "command": f"{hooks_dir}/session-end.sh"}]}],
    "PostToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": f"{hooks_dir}/token-accumulator.sh"}]}],
}

if "hooks" not in settings:
    settings["hooks"] = {}

for event, hook_list in new_hooks.items():
    if event not in settings["hooks"]:
        settings["hooks"][event] = hook_list
    else:
        existing_cmds = [
            h["command"]
            for entry in settings["hooks"][event]
            for h in entry.get("hooks", [])
        ]
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
echo "Start the backend:"
echo "  cd backend && go run main.go"
echo ""
echo "Use /track in any Claude Code session to log it."
