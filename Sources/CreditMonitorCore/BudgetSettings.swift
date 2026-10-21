import Foundation

public struct BudgetSettings: Codable, Sendable {
    public let version: Int
    public let weeklyBudgetCents: Int64

    public init(version: Int = 1, weeklyBudgetCents: Int64 = BudgetMath.defaultWeeklyBudgetCents) {
        self.version = version
        self.weeklyBudgetCents = weeklyBudgetCents
    }
}

public enum BudgetSettingsError: Error, LocalizedError {
    case invalidInput
    case invalidPrecision
    case negative
    case overflow
    case unknownVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Please enter a valid amount (for example 1000 or 1000.00)."
        case .invalidPrecision:
            return "Amount supports up to 2 decimal places."
        case .negative:
            return "Budget cannot be negative."
        case .overflow:
            return "Budget is too large to represent safely."
        case .unknownVersion(let version):
            return "Unsupported settings version \(version)."
        }
    }
}

public final class BudgetSettingsStore: @unchecked Sendable {
    public let settingsURL: URL

    public init(dataDirectory: URL) {
        self.settingsURL = dataDirectory.appendingPathComponent("settings-v1.json")
    }

    public func loadOrDefault() throws -> BudgetSettings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return BudgetSettings()
        }
        let data = try Data(contentsOf: settingsURL)
        let decoder = JSONDecoder()
        let settings = try decoder.decode(BudgetSettings.self, from: data)
        guard settings.version == 1 else {
            throw BudgetSettingsError.unknownVersion(settings.version)
        }
        _ = try BudgetMath.budgetNano(fromCents: settings.weeklyBudgetCents)
        return settings
    }

    public func save(_ settings: BudgetSettings) throws {
        guard settings.version == 1 else {
            throw BudgetSettingsError.unknownVersion(settings.version)
        }
        _ = try BudgetMath.budgetNano(fromCents: settings.weeklyBudgetCents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try AtomicFileWriter.write(data, to: settingsURL, mode: 0o600)
    }

    public static func parseBudgetCents(input: String) throws -> Int64 {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw BudgetSettingsError.invalidInput
        }
        if trimmed.contains(",") || trimmed.lowercased().contains("e") {
            throw BudgetSettingsError.invalidInput
        }
        let regex = try NSRegularExpression(pattern: #"^\d+(\.\d{1,2})?$"#)
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard regex.firstMatch(in: trimmed, range: range) != nil else {
            throw BudgetSettingsError.invalidPrecision
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard let dollars = Int64(parts[0]) else {
            throw BudgetSettingsError.overflow
        }
        let centsPart: Int64
        if parts.count == 1 {
            centsPart = 0
        } else {
            let fraction = String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0)
            guard let parsed = Int64(fraction) else {
                throw BudgetSettingsError.invalidInput
            }
            centsPart = parsed
        }
        let dollarsInCents = try BudgetMath.multiplyExact(dollars, 100)
        let total = try BudgetMath.addExact(dollarsInCents, centsPart)
        if total < 0 { throw BudgetSettingsError.negative }
        _ = try BudgetMath.budgetNano(fromCents: total)
        return total
    }
}
