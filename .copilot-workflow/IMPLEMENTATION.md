# Implementation

Implemented the user's simplified manual deduction flow. No history UI or
individual transaction records are retained.

## Summary

- Added a footer "扣除" button using the existing Frost money editor, with a
  remaining-balance preview and explicit confirmation.
- Positive amounts accumulate in the current week's spending without changing
  the budget or automatic usage ledger. Only a week boundary and total cents
  are persisted, in a separate atomically written file.
- The existing Monday 01:00 UTC+8 boundary excludes the previous week's total;
  a one-shot weekly timer updates an idle app without continuous polling.
- Saves run on the serial coordinator independently of log scanning, so a
  completed scan cannot overwrite a manual deduction.
- Parsing, overflow checks, corrupt-state blocking, incomplete-data bounds,
  error reporting, and duplicate-click prevention apply to deductions.
- Removed the initially requested history/deletion flow after the user explicitly
  narrowed the task to simple deduction.

## Files changed

- `Sources/CreditMonitorCore/ManualUsage.swift`: weekly total and atomic persistence.
- `Sources/CreditMonitorCore/Budget.swift`: combined spending calculations.
- `Sources/CopilotCreditMonitor/MonitorController.swift`: preview, save, weekly refresh.
- `Sources/CopilotCreditMonitor/AppDelegate.swift`: action wiring.
- `Sources/CopilotCreditMonitor/PopoverViewController.swift`: shared money editor.
- `Tests/CreditMonitorCoreTests/ManualUsageTests.swift`: synthetic unit-test source.
- `README.md`: deduction usage, scope, persistence, and screenshot age.

## Validation

- Debug build and release app packaging completed successfully.
- The added unit-test source type-checks with the Swift Testing compiler plugin.
- Ad-hoc bundle signature verified.
- No tests were executed, and no deduction was inserted into the user's real data.
- Attempting to compile all existing test sources exposed a pre-existing access
  error at `PersistenceAndSchedulingTests.swift:58`: `FileCursor` has no public
  memberwise initializer. This unrelated source was left unchanged; the new test
  file was type-checked independently.

## Blockers

No app-build blockers. Formal review and user-run behavioral tests remain pending.
