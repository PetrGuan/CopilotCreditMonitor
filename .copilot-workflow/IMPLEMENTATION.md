# Implementation

Implemented the planned native AppKit menu bar monitor with a full scanner/coordinator
refactor for large-log startup reliability, bounded memory/concurrency, official usage
field parsing, and non-blocking settings/save flows.

No GitHub issue/PR/commit/push actions were taken in this implementation round,
per updated request authorization.

## Summary

- Built a Swift Package with:
  - `CreditMonitorCore` library target (budget math, usage parser, scanner, ledger/settings persistence).
  - `CopilotCreditMonitor` executable target (AppKit menu bar app).
  - `CreditMonitorCoreTests` synthetic test sources (added only, not executed).
- Implemented local-only usage accounting:
  - Parses `session.usage_record` events from `events.jsonl` using typed decoding.
  - Uses official fields `data.usage.aiCreditsStatus` + `data.usage.isByok` +
    `data.usage.copilotUsage.totalNanoAiu`.
  - Excludes BYOK before usage interpretation.
  - Strict Int64 nano decoding rejects bool/fraction/string values.
  - Deduplicates by SHA-256(apiCallId), with event ID fallback.
  - Preserves partial/unavailable semantics (lower/upper bound display).
  - Handles incremental scan with cursor offsets and trailing partial JSONL lines.
  - Handles truncate/replace via inode/offset reset behavior.
  - Adds parser revision backfill: old cursor state replays files safely without
    deleting existing entries; complete records can upgrade old partial entries.
- Implemented scanner performance/safety surfaces:
  - Bounded file concurrency (default 3, constrained to 2–4).
  - Workers own parser/file state only; no shared mutable ledger in worker threads.
  - Deterministic serial merge of per-file deltas independent of worker completion order.
  - Bounded-snapshot EOF scanning so active writers cannot extend one scan indefinitely.
  - Warm unchanged files skip read I/O (inode/size/mtime/cursor match).
  - Linear newline scan via `memchr` over chunk buffers; no per-line prefix removal loop.
  - Chunk-level progress byte deltas (not only per-file completion) with coordinator-side
    throttling to <=5 updates/sec.
  - Single-line size bound enforcement (not whole-file buffering).
  - Parse failures now fail the scan transaction (source + byte offset) and do not commit
    cursor/aggregate updates; only unknown event / BYOK are skipped.
- Implemented budget semantics:
  - Default weekly budget `$1,000.00` (`100000` cents).
  - Integer-cent and Int64 nano-unit arithmetic.
  - 100 credits = $1, 1 credit = 1e9 nano units.
  - Week boundary fixed at Monday 01:00 UTC+8.
  - Save budget applies immediately to current week without clearing usage.
- Implemented AppKit UI and behavior:
  - `NSStatusItem` icon with transient popover.
  - Summary card with remaining/used/budget/progress/reset/coverage/status.
  - Settings mode in same popover via gear button.
  - Input validation (non-negative, up to 2 decimals, no scientific notation).
  - Preview of post-save remaining in settings (`≤` preview when current data is partial).
  - Save failure stays in settings with explicit error.
  - Remaining percentage text now matches the “剩余额度” label semantics.
- Implemented runtime reliability surfaces:
  - Single-instance lock file via `flock`.
  - Background serial coordinator queue plus dedicated scan queue; coordinator dispatches
    scan work asynchronously and returns immediately.
  - Per-scan lock-protected cancellation flag used by workers; stop flips cancellation
    synchronously and prevents late UI callbacks after stop.
  - FSEvents watcher with `events.jsonl` filtering, dropped/root-change warning state,
    and debounce with max 1s flush.
  - Coalesced single pending scan request while one scan is in-flight.
  - In-flight status phases (discovering/scanning/merging/saving) and progress-limited
    publication (<=5 updates/sec).
  - Startup and scan states now distinguish untrusted initial import, stale cached reads,
    and explicit errors.
  - Data directory with 0700 and atomic writes for ledger/settings files.
  - Atomic writer fixed for first-save path (destination-missing rename path) and update path.
  - Corrupt ledger/settings load now blocks unsafe reset/overwrite and surfaces explicit error.
  - Ledger parser revision migration for legacy files without `parserRevision` now defaults
    to 0 instead of failing decode.
- Implemented packaging:
  - `scripts/build-app.sh` to create and ad-hoc sign `dist/CopilotCreditMonitor.app`.
  - `Resources/Info.plist` with `LSUIElement=true`, min macOS 13.
- Updated README with build/run behavior, coverage limits, and runtime/data paths.

## Files changed

- `Package.swift`
- `README.md`
- `Resources/Info.plist`
- `scripts/build-app.sh`
- `Sources/CreditMonitorCore/Budget.swift`
- `Sources/CreditMonitorCore/BudgetSettings.swift`
- `Sources/CreditMonitorCore/LedgerStore.swift`
- `Sources/CreditMonitorCore/SessionScanner.swift`
- `Sources/CreditMonitorCore/UsageRecord.swift`
- `Sources/CopilotCreditMonitor/AppConfiguration.swift`
- `Sources/CopilotCreditMonitor/AppDelegate.swift`
- `Sources/CopilotCreditMonitor/MonitorController.swift`
- `Sources/CopilotCreditMonitor/PopoverViewController.swift`
- `Sources/CopilotCreditMonitor/ProcessLock.swift`
- `Sources/CopilotCreditMonitor/SessionWatcher.swift`
- `Sources/CopilotCreditMonitor/StatusItemController.swift`
- `Sources/CopilotCreditMonitor/main.swift`
- `Tests/CreditMonitorCoreTests/BudgetMathTests.swift`
- `Tests/CreditMonitorCoreTests/BudgetSettingsTests.swift`
- `Tests/CreditMonitorCoreTests/PersistenceAndSchedulingTests.swift`
- `Tests/CreditMonitorCoreTests/SessionScannerTests.swift`
- `Tests/CreditMonitorCoreTests/UsageRecordParserTests.swift`

## Validation

Executed (and succeeded):

```bash
swift build -c release
bash scripts/build-app.sh
plutil -lint dist/CopilotCreditMonitor.app/Contents/Info.plist
codesign --verify --strict dist/CopilotCreditMonitor.app
```

Observed outcome:

- Build succeeded.
- App bundle produced at `dist/CopilotCreditMonitor.app`.
- Info.plist validation returned `OK`.
- codesign verify completed with success exit status.
- After the user's explicit runtime-diagnostic approval, the rebuilt application
  completed a real import, persisted a new ledger covering all discovered files,
  and displayed its normal updated state instead of an endless importing label.
  No session contents, identifiers, account amounts, or machine-specific diagnostics
  are included in this handoff.
- Runtime observation exposed another import blocker: valid tool-result records
  exceeded the initial 2 MiB record limit. The bound is now 64 MiB; per-chunk and
  per-record autorelease pools remain in place, with explicit errors above the cap.
- Added a synthetic regression fixture containing a multi-chunk non-usage record
  followed by a usage record, and fixed scanner fixture dates for reproducibility.
- This was an authorized app-running diagnostic, not a full correctness or
  cross-machine performance certification. Reviewer and manual acceptance remain pending.

Not executed by design:

- No tests (`swift test`, UI tests, integration tests) were run.

## Blockers

- None. Ready for review.

## UI simplification follow-up

- Removed the summary card's next-reset row, coverage/conversion notes, and routine
  update status/source/timestamp text at the user's request.
- Kept first-import progress, actual warnings/errors, and partial-balance semantics.
- Popover height follows visible content, including transitions to budget settings,
  rather than leaving blank space where the removed rows used to be.
- Accounting, weekly reset rules, and persisted settings are unchanged.

## Native visual redesign follow-up

- Rebuilt both pages using behind-window native vibrancy, subtle radial tint,
  hairline glass edges, and layered translucent cards.
- Replaced oversized stacked labels with a restrained header, a dominant monetary
  figure, small secondary labels, and a two-column usage/proportion card.
- Replaced stock form chrome with a rounded USD input surface, focus accent,
  dedicated budget preview, and a primary save action.
- Added SF Symbol controls, damped spring hover/press/page/progress transitions,
  Reduce Motion support, keyboard input, and accessible control names.
- Kept the content width fixed while fitting each page's height; large monetary
  values adapt their font size instead of expanding the popover.
- Budget input previews now update on text editing; unchanged budgets cannot be
  saved unnecessarily. Closing the popover discards drafts, and stale save callbacks
  cannot reopen an old settings page.
- Inspected captures of the actual running summary and settings popovers; captures
  containing local account amounts are kept outside the repository.
- No accounting/scanning logic changed, and no test suite was run.
