import CryptoKit
import Foundation

public enum UsageStatus: String, Codable, Sendable {
    case complete
    case partial
    case unavailable
}

public struct UsageEntry: Codable, Sendable {
    public let key: String
    public let timestamp: Date
    public let status: UsageStatus
    public let nanoUnits: Int64
    public let firstSeenSource: String

    public init(key: String, timestamp: Date, status: UsageStatus, nanoUnits: Int64, firstSeenSource: String) {
        self.key = key
        self.timestamp = timestamp
        self.status = status
        self.nanoUnits = nanoUnits
        self.firstSeenSource = firstSeenSource
    }
}

public struct ParsedUsageRecord: Sendable {
    public let key: String
    public let timestamp: Date
    public let status: UsageStatus
    public let nanoUnits: Int64
}

public enum UsageParseError: Error, LocalizedError {
    case invalidJSON(String)
    case missingTimestamp
    case missingIdentifier
    case invalidNanoValue
    case invalidStatus(String)
    case completeMissingAmount
    case unknownEvent
    case byokExcluded
    case conflictingCompleteAmounts

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail):
            return "Invalid JSON line: \(detail)"
        case .missingTimestamp:
            return "Usage event is missing timestamp."
        case .missingIdentifier:
            return "Usage event missing both apiCallId and event id."
        case .invalidNanoValue:
            return "Usage event has invalid nano amount."
        case .invalidStatus(let status):
            return "Usage event has unsupported status '\(status)'."
        case .completeMissingAmount:
            return "Complete usage event has no amount."
        case .unknownEvent:
            return "Event type is not usage; ignored."
        case .byokExcluded:
            return "BYOK usage is excluded."
        case .conflictingCompleteAmounts:
            return "Conflicting complete usage amount for the same request."
        }
    }
}

public struct UsageRecordParser {
    public static let perRequestNanoLimit: Int64 = 1_000_000_000_000_000_000
    public static let parserRevision = 2

    private let fractionalTimestampFormatter: ISO8601DateFormatter
    private let basicTimestampFormatter: ISO8601DateFormatter
    private let decoder = JSONDecoder()

    public init() {
        fractionalTimestampFormatter = ISO8601DateFormatter()
        fractionalTimestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        basicTimestampFormatter = ISO8601DateFormatter()
        basicTimestampFormatter.formatOptions = [.withInternetDateTime]
    }

    public func parseUsageLine(_ lineData: Data) throws -> ParsedUsageRecord {
        let typeEnvelope: EventTypeEnvelope
        do {
            typeEnvelope = try decoder.decode(EventTypeEnvelope.self, from: lineData)
        } catch {
            throw UsageParseError.invalidJSON(error.localizedDescription)
        }
        guard typeEnvelope.type == "session.usage_record" else {
            throw UsageParseError.unknownEvent
        }
        let envelope: UsageEnvelope
        do {
            envelope = try decoder.decode(UsageEnvelope.self, from: lineData)
        } catch {
            throw UsageParseError.invalidJSON(error.localizedDescription)
        }
        guard let data = envelope.data else {
            throw UsageParseError.invalidJSON("missing data envelope")
        }
        guard data.usage?.isByok != true else {
            throw UsageParseError.byokExcluded
        }
        let time = data.requestTime ?? envelope.timestamp
        guard let time else {
            throw UsageParseError.missingTimestamp
        }
        let timestamp = try parseISO8601(time)

        let keySource: String
        if let apiCallID = data.usage?.apiCallId, !apiCallID.isEmpty {
            keySource = "api:\(apiCallID)"
        } else if let apiCallID = data.apiCallId, !apiCallID.isEmpty {
            keySource = "api:\(apiCallID)"
        } else if let eventID = envelope.id, !eventID.isEmpty {
            keySource = "event:\(eventID)"
        } else {
            throw UsageParseError.missingIdentifier
        }
        let key = Self.sha256Hex(keySource)

        let usage = data.usage
        let rawStatus = usage?.aiCreditsStatus?.lowercased()
        let rawNano = usage?.copilotUsage?.totalNanoAiu?.value

        let status: UsageStatus
        switch rawStatus {
        case .none:
            status = rawNano == nil ? .unavailable : .partial
        case "complete":
            status = .complete
        case "partial":
            status = .partial
        case "unavailable":
            status = .unavailable
        case let unknown?:
            throw UsageParseError.invalidStatus(unknown)
        }

        if status == .unavailable {
            return ParsedUsageRecord(key: key, timestamp: timestamp, status: .unavailable, nanoUnits: 0)
        }
        guard let nano = rawNano else {
            if status == .complete {
                throw UsageParseError.completeMissingAmount
            }
            return ParsedUsageRecord(key: key, timestamp: timestamp, status: .unavailable, nanoUnits: 0)
        }
        guard nano >= 0, nano <= Self.perRequestNanoLimit else {
            throw UsageParseError.invalidNanoValue
        }
        return ParsedUsageRecord(key: key, timestamp: timestamp, status: status, nanoUnits: nano)
    }

    public static func merge(existing: UsageEntry?, incoming: ParsedUsageRecord, source: String) throws -> UsageEntry {
        guard let existing else {
            return UsageEntry(
                key: incoming.key,
                timestamp: incoming.timestamp,
                status: incoming.status,
                nanoUnits: incoming.nanoUnits,
                firstSeenSource: source
            )
        }
        switch (existing.status, incoming.status) {
        case (.complete, .complete):
            guard existing.nanoUnits == incoming.nanoUnits else {
                throw UsageParseError.conflictingCompleteAmounts
            }
            return existing
        case (.complete, _):
            return existing
        case (.partial, .complete), (.unavailable, .complete):
            return UsageEntry(
                key: existing.key,
                timestamp: existing.timestamp,
                status: .complete,
                nanoUnits: incoming.nanoUnits,
                firstSeenSource: existing.firstSeenSource
            )
        case (.partial, .partial):
            return UsageEntry(
                key: existing.key,
                timestamp: existing.timestamp,
                status: .partial,
                nanoUnits: max(existing.nanoUnits, incoming.nanoUnits),
                firstSeenSource: existing.firstSeenSource
            )
        case (.unavailable, .partial):
            return UsageEntry(
                key: existing.key,
                timestamp: existing.timestamp,
                status: .partial,
                nanoUnits: incoming.nanoUnits,
                firstSeenSource: existing.firstSeenSource
            )
        case (_, .unavailable):
            return existing
        }
    }

    private func parseISO8601(_ value: String) throws -> Date {
        if let date = fractionalTimestampFormatter.date(from: value) {
            return date
        }
        if let date = basicTimestampFormatter.date(from: value) {
            return date
        }
        throw UsageParseError.invalidJSON("timestamp '\(value)' is not ISO-8601")
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct StrictInt64: Decodable, Sendable {
    let value: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int64.self) {
            value = intValue
            return
        }
        if (try? container.decode(Bool.self)) != nil ||
            (try? container.decode(Double.self)) != nil ||
            (try? container.decode(String.self)) != nil {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected strict Int64.")
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected strict Int64.")
    }
}

private struct UsageEnvelope: Decodable, Sendable {
    let type: String?
    let id: String?
    let timestamp: String?
    let data: UsageDataEnvelope?
}

private struct EventTypeEnvelope: Decodable, Sendable {
    let type: String?
}

private struct UsageDataEnvelope: Decodable, Sendable {
    let apiCallId: String?
    let requestTime: String?
    let usage: UsagePayload?
}

private struct UsagePayload: Decodable, Sendable {
    let apiCallId: String?
    let aiCreditsStatus: String?
    let isByok: Bool?
    let copilotUsage: CopilotUsagePayload?
}

private struct CopilotUsagePayload: Decodable, Sendable {
    let totalNanoAiu: StrictInt64?
}
