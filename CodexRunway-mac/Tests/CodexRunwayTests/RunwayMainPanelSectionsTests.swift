import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Runway main panel sections")
struct RunwayMainPanelSectionsTests {
    @Test("section preferences control visibility")
    func preferencesControlVisibility() {
        var preferences = RunwayPreferences()
        preferences.showsTokenUsageHeatmap = false
        preferences.showsRateLimitResetToday = false
        preferences.showsCostSummary = false
        preferences.showsSessionRepairSummary = false
        preferences.showsRecentSessions = false

        let sections = RunwayMainPanelSections.orderedVisible(preferences: preferences)

        // localAllowance defaults on and sits last in the default module order.
        #expect(sections == [.quota, .quotaEstimate, .resetCredits, .localAllowance])
    }

    @Test("custom module order is honored")
    func customOrderIsHonored() {
        var preferences = RunwayPreferences()
        preferences.mainPanelModuleOrder = [
            .recentSessions,
            .sessionRepair,
            .apiCost,
            .resetCredits,
            .rateLimitResetToday,
            .tokenUsage,
            .quota,
        ]
        preferences.showsRecentSessions = true

        // A custom order is honored; modules it omits fall back to the default
        // order, which now ends with localAllowance.
        #expect(RunwayMainPanelSections.orderedVisible(preferences: preferences) == [
            .recentSessions,
            .sessionRepair,
            .apiCost,
            .quotaEstimate,
            .resetCredits,
            .rateLimitResetToday,
            .tokenHeatmap,
            .quota,
            .localAllowance,
        ])
    }

    @Test("quota and reset credits can be hidden without changing order")
    func hidesPreviouslyRequiredModules() {
        var preferences = RunwayPreferences()
        let order = preferences.mainPanelModuleOrder
        preferences.showsQuotaSummary = false
        preferences.showsResetCreditsSummary = false

        let sections = RunwayMainPanelSections.orderedVisible(preferences: preferences)

        #expect(!sections.contains(.quota))
        #expect(!sections.contains(.resetCredits))
        #expect(preferences.mainPanelModuleOrder == order)
    }

    @Test("quota estimate can be hidden")
    func quotaEstimateCanBeHidden() {
        var preferences = RunwayPreferences()
        #expect(RunwayMainPanelSections.orderedVisible(preferences: preferences)
            .contains(.quotaEstimate))

        preferences.showsQuotaEstimateSummary = false
        #expect(!RunwayMainPanelSections.orderedVisible(preferences: preferences)
            .contains(.quotaEstimate))
    }

    @Test("an API-key account hides subscription-only modules")
    func apiKeyAccountHidesSubscriptionModules() {
        var preferences = RunwayPreferences()
        preferences.showsQuotaEstimateSummary = true
        preferences.showsResetCreditsSummary = true
        preferences.showsCostSummary = true
        preferences.showsQuotaSummary = true
        preferences.showsTokenUsageHeatmap = true

        // Subscription-only modules never appear for a relay key.
        let withoutBalance = RunwayMainPanelSections.orderedVisible(
            preferences: preferences, isAPIKeyAccount: true, relayHasBalance: false)
        #expect(!withoutBalance.contains(.quotaEstimate))
        #expect(!withoutBalance.contains(.resetCredits))
        #expect(!withoutBalance.contains(.apiCost))
        #expect(!withoutBalance.contains(.localAllowance))
        // Nothing to put in the quota module: no dashboard token and no readable
        // balance. Dropped rather than rendered as an empty frame.
        #expect(!withoutBalance.contains(.quota))
        #expect(withoutBalance.contains(.tokenHeatmap))

        // With a balance available the quota module is exactly what shows it.
        let withBalance = RunwayMainPanelSections.orderedVisible(
            preferences: preferences, isAPIKeyAccount: true, relayHasBalance: true)
        #expect(withBalance.contains(.quota), "the relay balance lives in this module")
        // Still no subscription modules.
        #expect(!withBalance.contains(.quotaEstimate))
        #expect(!withBalance.contains(.localAllowance))
    }

    @Test("a Codex account still shows subscription modules")
    func codexAccountKeepsSubscriptionModules() {
        let sections = RunwayMainPanelSections.orderedVisible(
            preferences: RunwayPreferences(),
            isAPIKeyAccount: false)
        #expect(sections.contains(.quotaEstimate))
        #expect(sections.contains(.resetCredits))
        #expect(sections.contains(.apiCost))
    }
}
