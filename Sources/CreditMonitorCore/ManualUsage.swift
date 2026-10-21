import Foundation

public enum ManualUsageError: Error, LocalizedError {
    case positiveAmountRequired
    case invalidData
    case unknownVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .positiveAmountRequired: return "扣除金额必须大于零。"
        case .invalidData: return "手动扣除数据损坏，无法安全读取或保存。"
        case .unknownVersion(let version): return "不支持的手动扣除数据版本：\(version)。"
        }
    }
}

public struct ManualUsage: Codable, Sendable, Equatable {
    public let version: Int
    public let weekStart: Date?
    public let amountCents: Int64

    public init(version: Int = 1, weekStart: Date? = nil, amountCents: Int64 = 0) {
        self.version = version
        self.weekStart = weekStart
        self.amountCents = amountCents
    }

    public func currentAmountCents(at date: Date) -> Int64 {
        weekStart == BudgetMath.weekWindow(containing: date).start ? amountCents : 0
    }

    public func adding(input: String, now: Date) throws -> ManualUsage {
        try validate()
        let cents = try ManualUsageStore.parseAmountCents(input: input)
        let next = ManualUsage(
            weekStart: BudgetMath.weekWindow(containing: now).start,
            amountCents: try BudgetMath.addExact(currentAmountCents(at: now), cents)
        )
        try next.validate()
        return next
    }

    func validate() throws {
        guard version == 1 else { throw ManualUsageError.unknownVersion(version) }
        _ = try BudgetMath.budgetNano(fromCents: amountCents)
        if let weekStart {
            guard weekStart >= .distantPast, weekStart <= .distantFuture,
                  BudgetMath.weekWindow(containing: weekStart).start == weekStart else {
                throw ManualUsageError.invalidData
            }
        } else if amountCents != 0 {
            throw ManualUsageError.invalidData
        }
    }
}

public final class ManualUsageStore: Sendable {
    public let usageURL: URL

    public init(dataDirectory: URL) {
        usageURL = dataDirectory.appendingPathComponent("manual-usage-v1.json")
    }

    public func load() throws -> ManualUsage {
        guard FileManager.default.fileExists(atPath: usageURL.path) else { return ManualUsage() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let usage = try decoder.decode(ManualUsage.self, from: Data(contentsOf: usageURL))
        try usage.validate()
        return usage
    }

    public func save(_ usage: ManualUsage) throws {
        try usage.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFileWriter.write(try encoder.encode(usage), to: usageURL, mode: 0o600)
    }

    public static func parseAmountCents(input: String) throws -> Int64 {
        let cents = try BudgetSettingsStore.parseBudgetCents(input: input)
        guard cents > 0 else { throw ManualUsageError.positiveAmountRequired }
        return cents
    }
}
