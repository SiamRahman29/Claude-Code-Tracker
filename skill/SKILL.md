# cctracker skill

## Tracking Status

When `CCTRACKER_ENABLED=1` in your Claude Code settings, all sessions are tracked
automatically. No manual action required.

Data recorded per session: duration, token cost, model, plugins.

To disable tracking: set `CCTRACKER_ENABLED=0` in `~/.claude/settings.json` env block,
then re-run `bash skill/install.sh` to apply the change.
