import Foundation

public enum LedgerError: Error, LocalizedError {
    case unknownVersion(Int)
    case invalidPath(String)
    case invalidLedger(String)

    public var errorDescription: String? {
        switch self {
        case .unknownVersion(let value):
            return "Unsupported ledger version \(value)."
        case .invalidPath(let path):
            return "Invalid path outside source root: \(path)"
        case .invalidLedger(let reason):
            return "Ledger validation failed: \(reason)"
        }
    }
}

public struct FileCursor: Codable, Sendable {
    public var inode: UInt64
    public var offset: Int64
    public var size: Int64
    public var mtimeSeconds: Int64
}

public struct Ledger: Codable, Sendable {
    public var version: Int
    public var parserRevision: Int
    public var sourceDirectories: [String]
    public var cursors: [String: FileCursor]
    public var entries: [String: UsageEntry]
    public var lastSuccessfulScanAt: Date?

    public init(
        version: Int = 1,
        parserRevision: Int = 0,
        sourceDirectories: [String] = [],
        cursors: [String: FileCursor] = [:],
        entries: [String: UsageEntry] = [:],
        lastSuccessfulScanAt: Date? = nil
    ) {
        self.version = version
        self.parserRevision = parserRevision
        self.sourceDirectories = sourceDirectories
        self.cursors = cursors
        self.entries = entries
        self.lastSuccessfulScanAt = lastSuccessfulScanAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case parserRevision
        case sourceDirectories
        case cursors
        case entries
        case lastSuccessfulScanAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        parserRevision = try container.decodeIfPresent(Int.self, forKey: .parserRevision) ?? 0
        sourceDirectories = try container.decodeIfPresent([String].self, forKey: .sourceDirectories) ?? []
        cursors = try container.decodeIfPresent([String: FileCursor].self, forKey: .cursors) ?? [:]
        entries = try container.decodeIfPresent([String: UsageEntry].self, forKey: .entries) ?? [:]
        lastSuccessfulScanAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulScanAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(parserRevision, forKey: .parserRevision)
        try container.encode(sourceDirectories, forKey: .sourceDirectories)
        try container.encode(cursors, forKey: .cursors)
        try container.encode(entries, forKey: .entries)
        try container.encodeIfPresent(lastSuccessfulScanAt, forKey: .lastSuccessfulScanAt)
    }
}

public final class LedgerStore: @unchecked Sendable {
    public let dataDirectory: URL
    public let ledgerURL: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        self.ledgerURL = dataDirectory.appendingPathComponent("ledger-v1.json")
    }

    public func load() throws -> Ledger {
        try ensureDataDirectory()
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else {
            return Ledger()
        }
        let data: Data
        do {
            data = try Data(contentsOf: ledgerURL)
        } catch {
            throw LedgerError.invalidLedger("cannot read ledger: \(error.localizedDescription)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ledger: Ledger
        do {
            ledger = try decoder.decode(Ledger.self, from: data)
        } catch {
            throw LedgerError.invalidLedger("cannot decode ledger: \(error.localizedDescription)")
        }
        guard ledger.version == 1 else {
            throw LedgerError.unknownVersion(ledger.version)
        }
        try validate(ledger: ledger)
        return ledger
    }

    public func save(_ ledger: Ledger) throws {
        try ensureDataDirectory()
        try validate(ledger: ledger)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ledger)
        try AtomicFileWriter.write(data, to: ledgerURL, mode: 0o600)
    }

    public func ensureDataDirectory() throws {
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func validate(ledger: Ledger) throws {
        guard ledger.version == 1 else {
            throw LedgerError.unknownVersion(ledger.version)
        }
        for path in ledger.cursors.keys where !path.hasPrefix("/") {
            throw LedgerError.invalidPath(path)
        }
        for entry in ledger.entries.values where entry.nanoUnits < 0 {
            throw LedgerError.invalidLedger("negative nano amount in entry \(entry.key)")
        }
    }
}

enum AtomicFileWriter {
    static func write(_ data: Data, to destination: URL, mode: Int16) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard FileManager.default.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int(mode))]
        ) else {
            throw LedgerError.invalidLedger("failed to create temp file \(tempURL.path)")
        }
        let fileHandle = try FileHandle(forWritingTo: tempURL)
        try fileHandle.synchronize()
        try fileHandle.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int(mode))],
            ofItemAtPath: destination.path
        )
    }
}
