import CreditMonitorCore
import Foundation
import Testing

@Test("Week boundary uses Monday 01:00 UTC+8")
func weekBoundaryUTC8() throws {
    let date = ISO8601DateFormatter().date(from: "2026-10-25T16:59:59Z")!
    let window = BudgetMath.weekWindow(containing: date)
    let reset = ISO8601DateFormatter().string(from: window.end)
    #expect(reset == "2026-10-25T17:00:00Z")
}

@Test("Summarize complete usage")
func summarizeCompleteUsage() throws {
    let date = ISO8601DateFormatter().date(from: "2026-10-22T00:00:00Z")!
    let entries = [
        UsageEntry(
            key: "a",
            timestamp: date,
            status: .complete,
            nanoUnits: 100_000_000_000,
            firstSeenSource: "/tmp/x"
        ),
    ]
    let summary = try BudgetMath.summarize(entries: entries, budgetCents: 100_000, now: date)
    #expect(summary.usedLowerNano == 100_000_000_000)
}
