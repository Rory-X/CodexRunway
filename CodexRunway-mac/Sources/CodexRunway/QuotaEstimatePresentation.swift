import CodexRunwayCore
import Foundation
import SwiftUI

enum QuotaEstimatePresentation {
    static func unavailableText(_ reason: QuotaEstimateUnavailableReason, l10n: L10n) -> String {
        let key: L10nKey
        switch reason {
        case .missingCredits: key = .quotaEstimateMissingCredits
        case .zeroCreditsWithUsage: key = .quotaEstimateZeroCreditsWithUsage
        case .noUsage: key = .quotaEstimateNoUsage
        case .zeroPercent: key = .quotaEstimateZeroPercent
        case .unavailableWindow: key = .quotaEstimateUnavailableWindow
        }
        return l10n.text(key)
    }

    /// The explanatory note has to name the metric the estimate is actually in:
    /// a Team plan has no Credits, so the Credits wording would misdescribe it.
    static func infoText(_ snapshot: QuotaEstimateSnapshot, l10n: L10n) -> String {
        switch snapshot.metric {
        case .credits: return l10n.text(.quotaEstimateInfo)
        case .tokens: return l10n.text(.quotaEstimateInfoTokens)
        }
    }

    static func dataTimeText(_ snapshot: QuotaEstimateSnapshot, l10n: L10n) -> String {
        let stats = snapshot.statsThroughDate.map { String(format: l10n.text(.quotaEstimateStatsThrough), $0) }
        let updated = "\(l10n.text(.lastUpdated)) \(ResetCreditDateFormatter.updatedAt(snapshot.calculatedAt, language: l10n.language))"
        return [stats, updated].compactMap { $0 }.joined(separator: " · ")
    }

    /// Explains that the figure understates the allowance, and why.
    ///
    /// The analytics endpoint serves day buckets only through yesterday while the
    /// meter's percentage is live, so today's usage is missing from the numerator
    /// but already counted in the denominator. Saying so is the difference between
    /// the user reading this number as exact and reading it as the floor it is.
    static func approximationNoticeText(_ snapshot: QuotaEstimateSnapshot, l10n: L10n) -> String? {
        guard snapshot.windowsMismatch else { return nil }
        return l10n.text(.quotaEstimateWindowMismatch)
    }

    static func refreshErrorText(_ error: String?, l10n: L10n) -> String? {
        guard let error, !error.isEmpty else { return nil }
        return "\(l10n.text(.quotaEstimateShowingPreviousData))\n\(error)"
    }
}

struct QuotaEstimateDataStatusView: View {
    var snapshot: QuotaEstimateSnapshot
    var error: String?
    var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(QuotaEstimatePresentation.dataTimeText(snapshot, l10n: l10n))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let lagText = QuotaEstimatePresentation.approximationNoticeText(snapshot, l10n: l10n) {
                Text(lagText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorText = QuotaEstimatePresentation.refreshErrorText(error, l10n: l10n) {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
