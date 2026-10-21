import CreditMonitorCore
import Foundation
import Testing

private let manualNow = ISO8601DateFormatter().date(from: "2026-10-22T00:00:00Z")!

private func localUsage(status: UsageStatus = .complete) -> UsageEntry {
    UsageEntry(key: "local", timestamp: manualNow, status: status,
               nanoUnits: 25_720 * BudgetMath.nanoPerCent, firstSeenSource: "/sample/events.jsonl")
}

@Test("Manual dollar amounts require positive cents and exact precision")
func manualAmountValidation() throws {
    #expect(try ManualUsageStore.parseAmountCents(input: " 50.25 ") == 5_025)
    #expect(try ManualUsageStore.parseAmountCents(input: "0.01") == 1)
    for input in ["0", "0.00", "-5", "1.001", "1e2", "1,000", "", "NaN", "9223372036854775807"] {
        #expect(throws: (any Error).self) { try ManualUsageStore.parseAmountCents(input: input) }
    }
}

@Test("Manual deductions accumulate without changing budget or automatic usage")
func manualUsageAccumulates() throws {
    let usage = try ManualUsage().adding(input: "50", now: manualNow)
        .adding(input: "25.50", now: manualNow)
    #expect(usage.amountCents == 7_550)
    let summary = try BudgetMath.summarize(entries: [localUsage()], budgetCents: 100_000,
                                          now: manualNow, manualUsage: usage)
    #expect(summary.usedLowerNano == 33_270 * BudgetMath.nanoPerCent)
    #expect(summary.remainingUpperNano == 66_730 * BudgetMath.nanoPerCent)
    #expect(summary.manualUsedNano == 7_550 * BudgetMath.nanoPerCent)
    #expect(summary.eventCount == 1)
    #expect(!summary.hasIncompleteData)
    #expect(summary.budgetCents == 100_000)
    let changedBudget = try BudgetMath.summarize(entries: [localUsage()], budgetCents: 50_000,
                                               now: manualNow, manualUsage: usage)
    #expect(changedBudget.usedLowerNano == summary.usedLowerNano)
    #expect(changedBudget.remainingUpperNano == 16_730 * BudgetMath.nanoPerCent)
}

@Test("Deductions reset at Monday 01:00 UTC+8 without carrying into the next week")
func manualWeeklyBoundary() throws {
    let reset = BudgetMath.weekWindow(containing: manualNow).end
    let usage = try ManualUsage().adding(input: "10", now: reset.addingTimeInterval(-1))
    #expect(usage.currentAmountCents(at: reset.addingTimeInterval(-1)) == 1_000)
    #expect(usage.currentAmountCents(at: reset) == 0)
    let after = try BudgetMath.summarize(entries: [UsageEntry](), budgetCents: 100_000,
                                        now: reset, manualUsage: usage)
    #expect(after.manualUsedNano == 0)
    let next = try usage.adding(input: "20", now: reset)
    #expect(next.weekStart == reset)
    #expect(next.amountCents == 2_000)
    #expect(next.currentAmountCents(at: reset.addingTimeInterval(-1)) == 0)
}

@Test("Manual usage preserves partial bounds and never certifies absent local usage")
func manualPartialUsage() throws {
    let usage = try ManualUsage().adding(input: "50", now: manualNow)
    let partial = try BudgetMath.summarize(entries: [localUsage(status: .partial)], budgetCents: 100_000,
                                          now: manualNow, manualUsage: usage)
    #expect(partial.hasIncompleteData)
    #expect(partial.usedLowerNano == 30_720 * BudgetMath.nanoPerCent)
    let manualOnly = try BudgetMath.summarize(entries: [UsageEntry](), budgetCents: 100_000,
                                             now: manualNow, manualUsage: usage)
    #expect(manualOnly.hasIncompleteData)
    #expect(manualOnly.eventCount == 0)
    #expect(manualOnly.remainingUpperNano == 95_000 * BudgetMath.nanoPerCent)
}

@Test("Manual spending may exceed a zero or nonzero budget")
func manualOverBudget() throws {
    let usage = try ManualUsage().adding(input: "1000", now: manualNow)
    let summary = try BudgetMath.summarize(entries: [localUsage()], budgetCents: 100_000,
                                          now: manualNow, manualUsage: usage)
    #expect(summary.remainingUpperNano == -25_720 * BudgetMath.nanoPerCent)
    let zero = try BudgetMath.summarize(entries: [localUsage()], budgetCents: 0,
                                       now: manualNow, manualUsage: usage)
    #expect(zero.remainingUpperNano == -125_720 * BudgetMath.nanoPerCent)
}

@Test("Manual and combined totals reject overflow")
func manualOverflow() throws {
    let usage = try ManualUsage().adding(input: "92233720.36", now: manualNow)
    #expect(throws: BudgetError.self) { try usage.adding(input: "0.50", now: manualNow) }
    #expect(throws: BudgetError.self) {
        try BudgetMath.summarize(entries: [localUsage()], budgetCents: 100_000,
                                 now: manualNow, manualUsage: usage)
    }
}

@Test("Weekly total survives restart and automatic-ledger replacement")
func manualPersistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccm-manual-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ManualUsageStore(dataDirectory: root)
    #expect(try store.load() == ManualUsage())
    let usage = try ManualUsage().adding(input: "12.34", now: manualNow)
    try store.save(usage)
    let originalBytes = try Data(contentsOf: store.usageURL)
    try LedgerStore(dataDirectory: root).save(Ledger(parserRevision: 0))
    #expect(try Data(contentsOf: store.usageURL) == originalBytes)
    let reloaded = try ManualUsageStore(dataDirectory: root).load()
    #expect(reloaded == usage)
    let updated = try reloaded.adding(input: "0.01", now: manualNow)
    try store.save(updated)
    #expect(try store.load().amountCents == 1_235)
}

@Test("Corrupt manual data is not replaced with a zero default")
func manualCorruption() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccm-manual-corrupt-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ManualUsageStore(dataDirectory: root)
    let corrupt = Data("not-json".utf8)
    try corrupt.write(to: store.usageURL)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(try Data(contentsOf: store.usageURL) == corrupt)
}

@Test("Invalid versions and invalid weekly totals cannot overwrite saved data")
func manualInvalidData() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccm-manual-invalid-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ManualUsageStore(dataDirectory: root)
    let usage = try ManualUsage().adding(input: "12.34", now: manualNow)
    try store.save(usage)
    #expect(throws: ManualUsageError.self) { try store.save(ManualUsage(version: 2)) }
    #expect(throws: ManualUsageError.self) { try store.save(ManualUsage(amountCents: 100)) }
    #expect(throws: ManualUsageError.self) {
        try store.save(ManualUsage(weekStart: manualNow, amountCents: 100))
    }
    #expect(throws: BudgetError.self) {
        try store.save(ManualUsage(weekStart: usage.weekStart, amountCents: -1))
    }
    #expect(try store.load() == usage)
}
