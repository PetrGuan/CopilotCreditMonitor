# Plan

User approved direct implementation without a separate planning confirmation.

## Problem

Spending on another computer is absent from the local logs. Provide a simple
positive-dollar deduction without introducing a history or record-management UI.

## Proposed approach

- Reuse the native Frost money editor for a new footer deduction button.
- Store only a week boundary and cumulative cents in `manual-usage-v1.json`.
- Merge that total into budget calculations, never into the scanner's ledger.
- Preserve incomplete-data bounds and errors; atomically persist before showing success.
- Ignore last week's total after the existing Monday 01:00 UTC+8 boundary.

## Files likely involved

Core manual usage storage and budget math; monitor/controller callbacks; native
popover editor; README; synthetic unit-test source.

## Implementation steps

Implement storage and calculation, wire async saving and preview, add a weekly
refresh timer, and extend the existing money editor without a history page.

## Validation

Build the release app and compile added unit-test source only. Do not execute tests.

## Risks and open questions

No undo/history is intentional per the user's latest scope correction. Manual
amounts must not be automatically re-imported elsewhere or they will be double-counted.
