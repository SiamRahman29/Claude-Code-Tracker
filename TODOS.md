# TODOS

## POST retry queue (P2)

**What:** When the backend is unreachable, write the failed POST payload to
`~/.cctracker/sessions/pending/<uuid>.json`. On next session-start.sh, flush any
pending payloads before continuing.

**Why:** Currently a backend blip silently loses session data. Fire-and-forget with
5s timeout means any transient outage costs you data permanently.

**Pros:** No data loss during backend downtime. Especially valuable for networked deployments.
**Cons:** ~2 hours to implement. Adds file I/O on every session start (stat pending dir).
Adds complexity to session-start.sh.

**Context:** Identified during always-on redesign (2026-04-14). The always-on watchdog
finalizes every session, so the window for data loss is now "backend unreachable at
session-end" rather than "user forgot /track". A retry queue closes the last gap.

**Depends on:** always-on tracking (v0.1.1) landing first.

## Optional lightweight session rating (P3)

**What:** After removing /track, all sessions default to task_type="other", outcome="complete",
rework_score=1, satisfaction=3. Consider a post-session prompt that fires from
session-watchdog.sh after POSTing — e.g., a whiptail/dialog terminal UI asking for a
1-5 satisfaction rating, or a quick `/rate N` skill.

**Why:** The rework heatmap and satisfaction trend charts lose signal quality. With all
sessions at identical defaults, those dashboard panels show flat lines.

**Pros:** Restores semantic data without requiring pre-session manual work.
**Cons:** Post-exit prompts are intrusive (watchdog fires after terminal may be closed).
Terminal UI availability (whiptail, dialog) varies by OS. Adds complexity to watchdog.

**Context:** /track was removed in v0.1.1 to eliminate friction. This TODO explores
a less-friction replacement that captures some semantic signal without blocking the user.

**Depends on:** always-on tracking (v0.1.1) landing first.

## Dashboard: Per-section error/loading states

**What:** Replace the all-or-nothing error banner with per-section loading and error states.
Each dashboard section (heatmap, task trend, plugin table, etc.) shows its own spinner
while loading and its own inline error if its fetch fails.

**Why:** With v0.2 adding 5-6 parallel fetch calls, the probability of ANY single endpoint
failing increases. Currently a single backend error kills the entire dashboard view.
Per-section states make the dashboard resilient — if heatmap fails, the plugin table
still renders.

**Pros:** Better UX. Makes partial backend failures visible instead of silent or total.
**Cons:** More frontend code (~50 lines of JS scaffolding per section). Complexity in
the single-file HTML constraint.

**Context:** Identified during /plan-eng-review on 2026-04-12 for feat/implement-cctracker.
Current state: dashboard/index.html has a single showError() that clears the entire app
div. The section-level approach requires each render*() function to receive a status
(loading/error/data) and render accordingly.

**Depends on:** v0.2 (this PR) landing first — the multi-fetch pattern doesn't exist yet.

## v0.2: Analytics endpoints and dashboard

**What:** Implement the three new stat endpoints and dashboard additions designed in office-hours.

New endpoints (deferred from v0.1 PR — plan: implement-cctracker-design-20260412-155837.md):
1. `GET /api/stats/heatmap` — 7x24 weekday x hour grid with avg_rework per cell
2. `GET /api/stats/task_trend` — weekly session counts by task_type (last 12 weeks)
3. `GET /api/stats/personal_summary?user_hash=<hash>` — 30-day summary per developer

Dashboard additions:
4. 7x24 rework heatmap (CSS grid, cells colored green-to-red, hover tooltip)
5. Task rework bar chart and task trend grouped bar chart
6. 30-day summary card

**Why:** Without these, the dashboard shows sparse session rows and doesn't surface the
trends that make rework_score and satisfaction valuable. See design doc for full schema,
SQL workarounds (substr for RFC3339 timestamps), and implementation notes.

**Priority:** P1 — this is the main adoption gate identified in office-hours.

**Context:** Designed on 2026-04-12 in office-hours session. Eng review CLEAR (PLAN).
Key technical notes in design doc at:
~/.gstack/projects/SiamRahman29-Claude-Code-Tracker/siam-feat/implement-cctracker-design-20260412-155837.md

## Backend: Auth gate for write/delete endpoints (P3)

**What:** Add an optional API key gate to `DELETE /api/sessions/{id}` (and optionally
`POST /api/sessions`) so that publicly-hosted deployments are protected.

**Why:** Currently any client that can reach the backend URL can delete any session by ID.
Fine for localhost but risky for networked deployments.

**Approach:** Simple static API key via `CCTRACKER_API_KEY` env var. If set, require
`Authorization: Bearer <key>` on write/delete endpoints.

**Priority:** P3 — only matters when hosting publicly. Not a concern for localhost use.

## CI/CD: GitHub Actions release workflow

**What:** Add `.github/workflows/release.yml` that triggers on version tag push, builds
CGO-free Linux and macOS binaries, and attaches them to a GitHub Release.

**Why:** Currently users must clone and build locally. A binary download would lower
the install barrier.

**Approach:** `CGO_ENABLED=0 go build` with `GOOS=linux/darwin GOARCH=amd64/arm64`,
upload artifacts via `actions/upload-release-asset`.

**Priority:** P2 — useful for distribution, not needed for solo self-hosting.
