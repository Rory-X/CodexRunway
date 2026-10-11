import CodexRunwayCore
import SwiftUI

/// The local-allowance module: what is left of a window's dollar cap, recovered
/// from this machine's own session logs.
///
/// The allowance is fitted by regressing measured spend against the meter's
/// percentage, which is the only way to recover it — the usage API publishes a
/// percentage and never an absolute cap. Remaining is that same line evaluated at
/// the current percentage, so a window already partly spent before the first local
/// sample still reports correctly.
///
/// Kept as its own section rather than folded into the online estimate: the two use
/// different numerators, and showing both keeps a disagreement visible.
struct LocalAllowanceSection: View {
    var allowance: LocalQuotaAllowance?
    var error: String?
    var scannedAt: Date?
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void
    var onDetailsSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let allowance {
                allowanceCard(allowance)
            } else if let error, !error.isEmpty {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(l10n.text(isRefreshing ? .calculating : .notLoaded))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        RefreshableSectionHeader(
            title: l10n.text(.localAllowance),
            l10n: l10n,
            isRefreshing: isRefreshing,
            onRefresh: onRefresh)
    }

    private func allowanceCard(_ allowance: LocalQuotaAllowance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Remaining leads: that is the actionable number. The total is context
            // underneath, not the headline.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(remainingText(allowance))
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(l10n.text(.localAllowanceRemainingSuffix))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            progress(allowance)
            Text(totalText(allowance))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle(allowance))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The derivation is worth being able to audit, so the card offers it.
            SidePanelDisclosureRow(
                title: l10n.text(.localAllowanceDetails),
                action: onDetailsSelect)
            if !allowance.isReliable {
                // An unreliable fit must say so: over a narrow percentage span, one
                // integer step of quantization swings the slope by double digits.
                Text(l10n.text(.localAllowanceLowConfidence))
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .runwayCard(.sunken)
    }

    /// A thin bar showing consumed vs remaining, so the figure has a shape.
    private func progress(_ allowance: LocalQuotaAllowance) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor))
                Capsule()
                    .fill(allowance.isReliable
                        ? Color(nsColor: .systemBlue)
                        : Color(nsColor: .systemOrange))
                    .frame(width: max(1, proxy.size.width * allowance.usedFraction))
            }
        }
        .frame(height: 5)
    }

    private func remainingText(_ allowance: LocalQuotaAllowance) -> String {
        if let remaining = allowance.remainingUSD {
            return QuotaEstimateFormatting.usd(remaining)
        }
        // No priced models: the remaining token count is still meaningful.
        if let tokens = allowance.remainingTokens {
            return TokenUsageHeatmapBuilder.compactTokenCount(
                Int(tokens.rounded()), language: l10n.language)
        }
        return "—"
    }

    private func totalText(_ allowance: LocalQuotaAllowance) -> String {
        let percent = String(format: "%.0f%%", allowance.usedPercent)
        if let total = allowance.allowanceUSD {
            return String(
                format: l10n.text(.localAllowanceWindowTotal),
                QuotaEstimateFormatting.usd(total),
                percent)
        }
        let tokens = TokenUsageHeatmapBuilder.compactTokenCount(
            Int(allowance.allowanceTokens.rounded()), language: l10n.language)
        return String(
            format: l10n.text(.localAllowanceWindowTotalTokens), tokens, percent)
    }

    private func subtitle(_ allowance: LocalQuotaAllowance) -> String {
        let window = allowance.windowMinutes >= 10080
            ? l10n.text(.localAllowanceWeeklyWindow)
            : "\(allowance.windowMinutes / 60)h"
        var parts = [
            "\(l10n.text(.localAllowancePlan)) \(allowance.plan)",
            window,
            String(format: l10n.text(.localAllowanceSamples), allowance.sampleCount),
        ]
        if let scannedAt {
            parts.append(
                "\(l10n.text(.lastUpdated)) \(ResetCreditDateFormatter.updatedAt(scannedAt, language: l10n.language))")
        }
        return parts.joined(separator: " · ")
    }
}
