# Copilot Credit Monitor

A native macOS menu bar app for viewing the remaining weekly Copilot budget
reported by local CLI / SDK session logs.

**Status: planning complete; implementation has not started.**
There is no runnable app or release yet.

## Planned experience

- A menu bar icon opens a compact balance popover.
- View the remaining weekly dollar budget, spending, next reset, and refresh status.
- Native Swift + AppKit, targeting macOS 13 or later.
- Local processing without account login, telemetry, or a web frontend.

## Budget and coverage

The initial budget policy is **$1,000 per week**, with **100 credits = $1**,
resetting on **Monday at 01:00 Beijing time (UTC+8)**.
These are project budget rules, not a statement of GitHub pricing or entitlements.

This is a **local usage subtotal, not a GitHub account balance or invoice**.
Other computers, native IDE Chat, and GitHub web usage are not covered.
Incomplete credit records must be shown as bounds rather than an exact balance;
missing data and read failures must not appear as unused budget.

## Development plan

- [Request](.copilot-workflow/REQUEST.md)
- [Implementation plan](.copilot-workflow/PLAN.md)
- [Workflow status](.copilot-workflow/STATUS.md)

The agent-readable workflow documents are versioned. Machine-specific metadata
and generated workflow views remain local.
