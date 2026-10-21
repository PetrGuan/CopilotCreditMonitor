import CreditMonitorCore
import Foundation
import Testing

@Test("Atomic writer supports first save then update")
func atomicWriterFirstAndSecondSave() throws {
    let root = try makeTempRoot("ledger-save")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LedgerStore(dataDirectory: root)

    var ledger = Ledger()
    ledger.entries["k1"] = UsageEntry(
        key: "k1",
        timestamp: Date(timeIntervalSince1970: 1),
        status: .complete,
        nanoUnits: 1_000_000_000,
        firstSeenSource: "/tmp/a"
    )
    try store.save(ledger)

    ledger.entries["k2"] = UsageEntry(
        key: "k2",
        timestamp: Date(timeIntervalSince1970: 2),
        status: .partial,
        nanoUnits: 2_000_000_000,
        firstSeenSource: "/tmp/b"
    )
    try store.save(ledger)
    let loaded = try store.load()
    #expect(loaded.entries.count == 2)
}

@Test("Legacy ledger without parserRevision decodes as revision 0")
func legacyLedgerDecodesRevisionZero() throws {
    let root = try makeTempRoot("legacy-ledger")
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = """
    {"version":1,"sourceDirectories":[],"cursors":{},"entries":{}}
    """
    let file = root.appendingPathComponent("ledger-v1.json")
    try Data(raw.utf8).write(to: file)
    let store = LedgerStore(dataDirectory: root)
    let loaded = try store.load()
    #expect(loaded.parserRevision == 0)
}

@Test("Parser revision backfill replays and upgrades parser revision")
func parserRevisionBackfill() throws {
    let root = try makeTempRoot("revision-backfill")
    defer { try? FileManager.default.removeItem(at: root) }
    let s1 = root.appendingPathComponent("s1", isDirectory: true)
    try FileManager.default.createDirectory(at: s1, withIntermediateDirectories: true)
    let events = s1.appendingPathComponent("events.jsonl")
    let line = #"{"type":"session.usage_record","id":"e1","timestamp":"2026-10-22T00:00:00Z","data":{"usage":{"apiCallId":"a1","aiCreditsStatus":"complete","isByok":false,"copilotUsage":{"totalNanoAiu":1000000000}}}}"# + "\n"
    try Data(line.utf8).write(to: events)

    var ledger = Ledger(parserRevision: 0)
    ledger.cursors[events.path] = FileCursor(inode: 1, offset: 0, size: 0, mtimeSeconds: 0)
    let scanner = SessionScanner(sourceRoots: [root], workerCount: 2)
    let snapshot = try scanner.scan(ledger: ledger, now: Date())
    #expect(snapshot.ledger.parserRevision == UsageRecordParser.parserRevision)
    #expect(snapshot.ledger.entries.count == 1)
}

private func makeTempRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccm-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
