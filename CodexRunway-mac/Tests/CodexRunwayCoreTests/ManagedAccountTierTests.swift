import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Subscription tier resolution")
struct ManagedAccountTierTests {
    /// An API key is metered per token rather than by a ChatGPT subscription, so a
    /// `planType` it carries describes a different credential. Reporting that value
    /// would label a relay key as a Plus or Team subscriber.
    @Test("an API-key account is labelled API regardless of its planType")
    func apiKeyAccountsAreLabelledAPI() {
        for inherited in ["plus", "team", "pro", "enterprise", "business"] {
            let account = ManagedAccount(
                id: "api-1", authMode: .apiKey, displayName: "API",
                planType: inherited)
            #expect(
                account.subscriptionTier == .api,
                "planType \(inherited) must not leak onto an API-key account")
        }
    }

    /// An OAuth account's plan is real and still reported.
    @Test("an OAuth account still reports its own plan")
    func oauthAccountsReportTheirPlan() {
        let plus = ManagedAccount(
            id: "o-1", authMode: .oauth, displayName: "Plus", planType: "plus")
        #expect(plus.subscriptionTier == .plus)

        let team = ManagedAccount(
            id: "o-2", authMode: .oauth, displayName: "Team", planType: "team")
        #expect(team.subscriptionTier == .team)
    }

    @Test("an OAuth account with no plan is unknown rather than assumed")
    func oauthWithoutPlanIsUnknown() {
        let account = ManagedAccount(id: "o-3", authMode: .oauth, displayName: "New")
        #expect(account.subscriptionTier == .unknown)
    }
}
