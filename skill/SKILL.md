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
