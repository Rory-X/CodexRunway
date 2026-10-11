import CodexRunwayCore

enum RunwayMainPanelSection: Hashable {
    case quota
    case tokenHeatmap
    case rateLimitResetToday
    case quotaEstimate
    case localAllowance
    case resetCredits
    case apiCost
    case sessionRepair
    case recentSessions
}

enum RunwayMainPanelSections {
    /// Codex-subscription modules. A plain API-key account has no ChatGPT quota
    /// windows, reset credits, or subscription estimate, so these stay off its panel
    /// even when the matching preference is on.
    ///
    /// `localAllowance` measures a subscription's window by fitting this machine's own
    /// log against the server's meter, so it has nothing to say about a relay key.
    static let subscriptionOnlyModules: Set<MainPanelModule> = [
        .quotaEstimate, .localAllowance, .resetCredits, .apiCost,
    ]

    /// Modules a relay account shows only when it has something to put in them.
    ///
    /// `quota` renders the relay's balance when one is available — useful — and an
    /// empty Codex meter list when it is not. With no dashboard token and no readable
    /// balance there is nothing to display, so the module is dropped rather than
    /// rendered as an empty frame with an explanation the user cannot act on.
    static let relayModulesRequiringData: Set<MainPanelModule> = [.quota]

    static func orderedVisible(
        preferences: RunwayPreferences,
        isAPIKeyAccount: Bool = false,
        relayHasBalance: Bool = false
    ) -> [RunwayMainPanelSection] {
        RunwayPreferences.normalizedMainPanelModuleOrder(preferences.mainPanelModuleOrder)
            .filter { module in
                guard isAPIKeyAccount else { return true }
                if Self.subscriptionOnlyModules.contains(module) { return false }
                // A relay account keeps `quota` only when there is a balance to show.
                if Self.relayModulesRequiringData.contains(module) { return relayHasBalance }
                return true
            }
            .compactMap { section(for: $0, preferences: preferences) }
    }

    private static func section(
        for module: MainPanelModule,
        preferences: RunwayPreferences
    ) -> RunwayMainPanelSection? {
        switch module {
        case .quota:
            return preferences.showsQuotaSummary ? .quota : nil
        case .tokenUsage:
            return preferences.showsTokenUsageHeatmap ? .tokenHeatmap : nil
        case .rateLimitResetToday:
            return preferences.showsRateLimitResetToday ? .rateLimitResetToday : nil
        case .quotaEstimate:
            return preferences.showsQuotaEstimateSummary ? .quotaEstimate : nil
        case .localAllowance:
            return preferences.showsLocalAllowanceSummary ? .localAllowance : nil
        case .resetCredits:
            return preferences.showsResetCreditsSummary ? .resetCredits : nil
        case .apiCost:
            return preferences.showsCostSummary ? .apiCost : nil
        case .sessionRepair:
            return preferences.showsSessionRepairSummary ? .sessionRepair : nil
        case .recentSessions:
            return preferences.showsRecentSessions ? .recentSessions : nil
        }
    }
}
