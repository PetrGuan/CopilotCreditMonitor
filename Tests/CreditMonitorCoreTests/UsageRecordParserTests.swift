import CreditMonitorCore
import Foundation
import Testing

@Test("Parses usage record complete")
func parseCompleteUsage() throws {
    let line = """
    {"type":"session.usage_record","id":"evt1","timestamp":"2026-10-22T00:00:00Z","data":{"usage":{"apiCallId":"api-1","aiCreditsStatus":"complete","isByok":false,"copilotUsage":{"totalNanoAiu":1000000000}}}}
    """
    let parser = UsageRecordParser()
    let parsed = try parser.parseUsageLine(Data(line.utf8))
    #expect(parsed.status == .complete)
    #expect(parsed.nanoUnits == 1_000_000_000)
}

@Test("Treats missing aiCreditsStatus with amount as partial")
func parseMissingStatusAsPartial() throws {
    let line = """
    {"type":"session.usage_record","id":"evt2","timestamp":"2026-10-22T00:00:00Z","data":{"usage":{"apiCallId":"api-2","isByok":false,"copilotUsage":{"totalNanoAiu":2000000000}}}}
    """
    let parser = UsageRecordParser()
    let parsed = try parser.parseUsageLine(Data(line.utf8))
    #expect(parsed.status == .partial)
}

@Test("Excludes BYOK before usage interpretation")
func excludeByok() throws {
    let line = """
    {"type":"session.usage_record","id":"evt3","timestamp":"2026-10-22T00:00:00Z","data":{"usage":{"apiCallId":"api-3","aiCreditsStatus":"complete","isByok":true,"copilotUsage":{"totalNanoAiu":2000000000}}}}
    """
    let parser = UsageRecordParser()
    #expect(throws: UsageParseError.self) {
        _ = try parser.parseUsageLine(Data(line.utf8))
    }
}

@Test("Rejects fractional nano amount")
func rejectsFractionalNano() throws {
    let line = """
    {"type":"session.usage_record","id":"evt4","timestamp":"2026-10-22T00:00:00Z","data":{"usage":{"apiCallId":"api-4","aiCreditsStatus":"complete","isByok":false,"copilotUsage":{"totalNanoAiu":1.5}}}}
    """
    let parser = UsageRecordParser()
    #expect(throws: UsageParseError.self) {
        _ = try parser.parseUsageLine(Data(line.utf8))
    }
}
