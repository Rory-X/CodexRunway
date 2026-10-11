import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Status bar meter selection")
struct StatusBarMeterSelectionTests {
    @Test("Codex prefers 5-hour over weekly")
    func codexPrefersFiveHour() {
        let fiveHour = meter(title: "5h", usedPercent: 20, windowMinutes: 300)
        let weekly = meter(title: "weekly", usedPercent: 40, windowMinutes: 10_080)
        let pick = StatusBarMeterSelection.primaryStandardMeter(
            from: [weekly, fiveHour],
            preferredWindowMinutes: StatusBarMeterSelection.codexPreferredWindowMinutes)
        #expect(pick?.title == "5h")
    }

    @Test("Codex falls back to weekly when 5-hour is missing")
    func codexFallsBackToWeekly() {
        let weekly = meter(title: "weekly", usedPercent: 40, windowMinutes: 10_080)
        let model = meter(title: "gpt", usedPercent: 10, windowMinutes: 10_080, source: .modelSpecific)
        let pick = StatusBarMeterSelection.primaryStandardMeter(
            from: [model, weekly],
            preferredWindowMinutes: StatusBarMeterSelection.codexPreferredWindowMinutes)
        #expect(pick?.title == "weekly")
        #expect(pick?.source == .standard)
    }

    @Test("short window titles match Codex menu-bar wording")
    func shortWindowTitlesMatchCodex() {
        let l10n = L10n(language: .simplifiedChinese)
        #expect(StatusBarMeterSelection.shortWindowTitle(windowMinutes: 300, l10n: l10n) == "5小时")
        #expect(StatusBarMeterSelection.shortWindowTitle(windowMinutes: 10_080, l10n: l10n) == "每周")
        #expect(StatusBarMeterSelection.shortWindowTitle(windowMinutes: 30 * 24 * 60, l10n: l10n) == "每月")

        let long = meter(title: "周度包含额度", usedPercent: 27, windowMinutes: 10_080)
        #expect(StatusBarMeterSelection.withShortStatusBarTitle(long, l10n: l10n).title == "每周")
    }

    private func meter(
        title: String,
        usedPercent: Int,
        windowMinutes: Int,
        source: QuotaMeterSource = .standard)
        -> QuotaMeter
    {
        QuotaMeter(
            title: title,
            window: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: Date().addingTimeInterval(TimeInterval(windowMinutes * 60))),
            source: source)
    }
}
