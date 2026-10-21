import CreditMonitorCore
import Foundation
import Testing

@Test("Scanner handles chunk boundaries and trailing partial line")
func scannerHandlesChunkAndPartialLine() throws {
    let root = try makeTempRoot("scanner-partial")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("s1", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let events = session.appendingPathComponent("events.jsonl")
    let line1 = #"{"type":"session.usage_record","id":"e1","timestamp":"2026-10-22T00:00:00Z","data":{"usage":{"apiCallId":"a1","aiCreditsStatus":"complete","isByok":false,"copilotUsage":{"totalNanoAiu":1000000000}}}}"# + "\n"
    let line2Partial = #"{"type":"session.usage_record","id":"e2","timestamp":"2026-10-22T00:00:01Z","data":{"usage":{"apiCallId":"a2","aiCreditsStatus":"complete","isByok":false,"copilotUsage":{"totalNanoAiu":2000000000}}}}"#
    try Data((line1 + line2Partial).utf8).write(to: events)

    let scanner = SessionScanner(sourceRoots: [root], workerCount: 2)
    let snapshot = try scanner.scan(ledger: Ledger(), now: fixtureNow())
    #expect(snapshot.ledger.entries.count == 1)
}

@Test("Scanner cancellation stops scan")
func scannerCancellationStopsScan() throws {
    let root = try makeTempRoot("scanner-cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("s1", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let events = session.appendingPathComponent("events.jsonl")
    let line = #"{"type":"session.usage_record","id":"e1","timestamp":"2026-10-22T00:00:00Z","data":{"usage":{"apiCallId":"a1","aiCreditsStatus":"complete","isByok":false,"copilotUsage":{"totalNanoAiu":1000000000}}}}"# + "\n"
    try Data(String(repeating: line, count: 2048).utf8).write(to: events)

    let scanner = SessionScanner(sourceRoots: [root], workerCount: 2)
    let cancelled = ScanCancellation(isCancelled: { true })
    #expect(throws: ScanError.self) {
        _ = try scanner.scan(ledger: Ledger(), now: fixtureNow(), cancellation: cancelled)
    }
}

@Test("Parallel scan merges duplicate keys deterministically")
func scannerParallelDedupDeterministic() throws {
    let root = try makeTempRoot("scanner-dedup")
    defer { try? FileManager.default.removeItem(at: root) }
    let s1 = root.appendingPathComponent("s1", isDirectory: true)
    let s2 = root.appendingPathComponent("s2", isDirectory: true)
    try FileManager.default.createDirectory(at: s1, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: s2, withIntermediateDirectories: true)

    let partialLine = #"{"type":"session.usage_record","id":"e1","timestamp":"2026-10-22T00:00:00Z","data":{"usage":{"apiCallId":"same","aiCreditsStatus":"partial","isByok":false,"copilotUsage":{"totalNanoAiu":1000000000}}}}"# + "\n"
    let completeLine = #"{"type":"session.usage_record","id":"e2","timestamp":"2026-10-22T00:00:01Z","data":{"usage":{"apiCallId":"same","aiCreditsStatus":"complete","isByok":false,"copilotUsage":{"totalNanoAiu":3000000000}}}}"# + "\n"
    try Data(partialLine.utf8).write(to: s1.appendingPathComponent("events.jsonl"))
    try Data(completeLine.utf8).write(to: s2.appendingPathComponent("events.jsonl"))

    let scanner = SessionScanner(sourceRoots: [root], workerCount: 4)
    let snapshot = try scanner.scan(ledger: Ledger(), now: fixtureNow())
    #expect(snapshot.ledger.entries.count == 1)
    let entry = snapshot.ledger.entries.values.first
    #expect(entry?.status == .complete)
    #expect(entry?.nanoUnits == 3_000_000_000)
}

@Test("Large non-usage records do not prevent subsequent usage ingestion")
func scannerHandlesLargeToolResult() throws {
    let root = try makeTempRoot("scanner-large-result")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("s1", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let events = session.appendingPathComponent("events.jsonl")
    let result = #"{"type":"tool.execution_complete","data":{"content":""#
        + String(repeating: "x", count: 3 * 1024 * 1024) + "\"}}\n"
    let usage = #"{"type":"session.usage_record","id":"e1","timestamp":"2026-10-22T00:00:00Z","data":{"usage":{"apiCallId":"a1","aiCreditsStatus":"complete","isByok":false,"copilotUsage":{"totalNanoAiu":1000000000}}}}"# + "\n"
    let data = Data((result + usage).utf8)
    try data.write(to: events)
    let snapshot = try SessionScanner(sourceRoots: [root]).scan(ledger: Ledger(), now: fixtureNow())
    #expect(snapshot.ledger.entries.count == 1)
    #expect(snapshot.ledger.cursors[events.path]?.offset == Int64(data.count))
}

private func fixtureNow() throws -> Date {
    try #require(ISO8601DateFormatter().date(from: "2026-10-22T01:00:00Z"))
}

private func makeTempRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccm-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
