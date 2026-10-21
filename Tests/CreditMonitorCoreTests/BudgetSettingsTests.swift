import CreditMonitorCore
import Testing

@Test("Parses two-decimal input")
func parseBudgetInput() throws {
    let cents = try BudgetSettingsStore.parseBudgetCents(input: "500.25")
    #expect(cents == 50_025)
}

@Test("Rejects scientific notation")
func parseBudgetRejectsScientific() {
    #expect(throws: BudgetSettingsError.self) {
        _ = try BudgetSettingsStore.parseBudgetCents(input: "1e3")
    }
}
