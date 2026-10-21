import Foundation

public enum BudgetError: Error, LocalizedError {
    case overflow
    case invalidBudget

    public var errorDescription: String? {
        switch self {
        case .overflow:
            return "Numeric overflow while computing budget totals."
        case .invalidBudget:
            return "Budget must be non-negative and within Int64 nano-unit range."
        }
    }
}

public struct BudgetSummary: Sendable, Codable {
    public let weekStart: Date
    public let nextReset: Date
    public let budgetCents: Int64
    public let budgetNano: Int64
    public let usedLowerNano: Int64
    public let remainingUpperNano: Int64
    public let partialCount: Int
    public let unavailableCount: Int
    public let eventCount: Int
    public let supportedEventCount: Int

    public var hasIncompleteData: Bool {
        partialCount > 0 || unavailableCount > 0
    }
}

public enum BudgetMath {
    public static let nanoPerCredit: Int64 = 1_000_000_000
    public static let creditsPerDollar: Int64 = 100
    public static let nanoPerCent: Int64 = nanoPerCredit
    public static let defaultWeeklyBudgetCents: Int64 = 100_000
    public static let beijingFixedOffsetSeconds = 8 * 60 * 60

    public static let beijingTimeZone = TimeZone(secondsFromGMT: beijingFixedOffsetSeconds)!

    public static func budgetNano(fromCents cents: Int64) throws -> Int64 {
        guard cents >= 0 else { throw BudgetError.invalidBudget }
        return try multiplyExact(cents, nanoPerCent)
    }

    public static func weekWindow(containing date: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijingTimeZone
        calendar.firstWeekday = 2

        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        components.weekday = 2
        components.hour = 0
        components.minute = 0
        components.second = 0
        let mondayStart = calendar.date(from: components)!
        var weekStart = calendar.date(byAdding: .hour, value: 1, to: mondayStart)!
        if date < weekStart {
            weekStart = calendar.date(byAdding: .day, value: -7, to: weekStart)!
        }
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        return (weekStart, weekEnd)
    }

    public static func summarize(
        entries: some Collection<UsageEntry>,
        budgetCents: Int64,
        now: Date
    ) throws -> BudgetSummary {
        let (weekStart, nextReset) = weekWindow(containing: now)
        let budgetNano = try budgetNano(fromCents: budgetCents)
        var usedLowerNano: Int64 = 0
        var partialCount = 0
        var unavailableCount = 0
        var eventCount = 0
        var supportedEventCount = 0

        for entry in entries {
            guard entry.timestamp >= weekStart, entry.timestamp < nextReset, entry.timestamp <= now else {
                continue
            }
            eventCount += 1
            switch entry.status {
            case .complete:
                supportedEventCount += 1
                usedLowerNano = try addExact(usedLowerNano, entry.nanoUnits)
            case .partial:
                supportedEventCount += 1
                partialCount += 1
                usedLowerNano = try addExact(usedLowerNano, entry.nanoUnits)
            case .unavailable:
                unavailableCount += 1
            }
        }

        let remainingUpperNano = try subtractExact(budgetNano, usedLowerNano)
        return BudgetSummary(
            weekStart: weekStart,
            nextReset: nextReset,
            budgetCents: budgetCents,
            budgetNano: budgetNano,
            usedLowerNano: usedLowerNano,
            remainingUpperNano: remainingUpperNano,
            partialCount: partialCount,
            unavailableCount: unavailableCount,
            eventCount: eventCount,
            supportedEventCount: supportedEventCount
        )
    }

    public static func addExact(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow { throw BudgetError.overflow }
        return result
    }

    public static func subtractExact(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        if overflow { throw BudgetError.overflow }
        return result
    }

    public static func multiplyExact(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        if overflow { throw BudgetError.overflow }
        return result
    }
}

public enum MoneyFormatter {
    public static func exactUSD(fromNano nano: Int64) -> String {
        format(nano: nano, rule: .plain)
    }

    public static func lowerBoundUSD(fromNano nano: Int64) -> String {
        format(nano: nano, rule: .floorTowardNegativeInfinity)
    }

    public static func upperBoundUSD(fromNano nano: Int64) -> String {
        format(nano: nano, rule: .ceilingTowardPositiveInfinity)
    }

    public static func percentage(usedNano: Int64, budgetNano: Int64) -> String {
        guard budgetNano > 0 else { return "—" }
        let pct = (Decimal(usedNano) / Decimal(budgetNano)) * 100
        return formatPercent(pct)
    }

    public static func remainingPercentage(remainingNano: Int64, budgetNano: Int64) -> String {
        guard budgetNano > 0 else { return "—" }
        let pct = (Decimal(remainingNano) / Decimal(budgetNano)) * 100
        return formatPercent(pct)
    }

    private static func formatPercent(_ value: Decimal) -> String {
        let pct = min(Decimal(100), max(Decimal(0), value))
        let number = NSDecimalNumber(decimal: pct)
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: number) ?? "0.00")%"
    }

    private enum RoundingRule {
        case plain
        case floorTowardNegativeInfinity
        case ceilingTowardPositiveInfinity
    }

    private static func format(nano: Int64, rule: RoundingRule) -> String {
        let centsDecimal = Decimal(nano) / Decimal(BudgetMath.nanoPerCent)
        var dollars = centsDecimal / Decimal(100)
        var rounded = Decimal()
        switch rule {
        case .plain:
            NSDecimalRound(&rounded, &dollars, 2, .plain)
        case .floorTowardNegativeInfinity:
            NSDecimalRound(&rounded, &dollars, 2, .down)
        case .ceilingTowardPositiveInfinity:
            NSDecimalRound(&rounded, &dollars, 2, .up)
        }
        if rounded == Decimal.zero {
            rounded = .zero
        }
        let number = NSDecimalNumber(decimal: rounded)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: number) ?? "$0.00"
    }
}
