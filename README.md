# Copilot Credit Monitor

A native macOS menu bar app for viewing remaining weekly Copilot budget from
local CLI / SDK session logs.

## What it does

- Menu bar icon only (no Dock icon / no main window).
- Click to open a Frost-style popover showing this week's remaining budget,
  used amount, budget amount, and remaining percentage.
  Reset details, coverage/conversion notes, and routine update timestamps are not
  shown in the popover. Import progress and actual errors remain visible when needed.
- Native glass material, compact two-column statistics, SF Symbol controls, and
  a focused budget editor replace stock form chrome. Subtle spring interactions
  respect the macOS Reduce Motion setting.
- Settings inside the same popover: edit weekly budget in USD.
- Saving a new budget **immediately recalculates current-week remaining**
  without clearing existing consumption records and without triggering a new log scan.
- Budget settings persist across restart in `settings-v1.json`.

## Budget and coverage rules

- Default weekly budget: **$1,000.00** (`100000` cents).
- Fixed conversion: **100 credits = $1**.
- Internal unit: **1 credit = 1,000,000,000 nano AI units**.
- Weekly reset boundary: **Monday 01:00 Beijing time (UTC+8 fixed offset)**.

This is a **local usage subtotal**, not account billing:

- Covered: local session-state logs on this machine.
- Not covered: GitHub web usage, other devices, and native IDE chat sources.

When data is incomplete:

- Used amount is shown as a lower bound (`至少`).
- Remaining amount is shown as an upper bound (`≤`).

## Scanner and startup behavior

- Scanner reads only `events.jsonl` inside first-level session directories under
  each configured session root.
- Parsing uses official fields:
  - `data.usage.aiCreditsStatus`
  - `data.usage.isByok`
  - `data.usage.apiCallId` (with fallback to legacy `data.apiCallId` and event ID)
  - `data.usage.copilotUsage.totalNanoAiu`
- BYOK records are excluded before usage classification.
- Bounded worker concurrency (2–4 workers, default 3), each with isolated parser
  state; file deltas are merged serially in deterministic path order.
- Scan memory is bounded by chunk/line limits plus retained usage entries, not by
  full input log size.
- Each JSONL record may be up to 64 MiB, allowing large tool-result events without
  rejecting otherwise valid session logs. Larger records produce an explicit error;
  they are never silently skipped. Temporary decoding allocations are released per
  record and chunk.
- Initial cold import may still read historical bytes to guarantee timestamp-based
  correctness; this can take time on very large log sets.
- Warm scans skip unchanged files (inode/size/mtime/cursor match) and avoid I/O for
  those files.
- During in-flight scan:
  - first startup keeps remaining unavailable until trustworthy completion,
  - subsequent scans keep cached values but mark them stale,
  - progress/status phases publish discovery/scanning/merging/saving.
- Record parse failure aborts the scan transaction for safety (no partial cursor commit).

## Build locally

```bash
swift build
bash scripts/build-app.sh
plutil -lint dist/CopilotCreditMonitor.app/Contents/Info.plist
codesign --verify --strict dist/CopilotCreditMonitor.app
```

App output:

`dist/CopilotCreditMonitor.app`

## Runtime paths

- Default session root: `~/.copilot/session-state`
- Optional override: `--session-dir <absolute-or-tilde-path>`
- Optional data root: `--data-dir <absolute-or-tilde-path>`
- Default data root: `~/Library/Application Support/CopilotCreditMonitor`

Persisted files:

- `ledger-v1.json` (usage ledger + cursors + parser revision)
- `settings-v1.json` (weekly budget cents)
- `monitor.lock` (single-instance lock)

## Design references

- [Frost appearances](docs/design/frost-appearances.png)
- [Frost weekly budget settings](docs/design/frost-budget-settings.png)
