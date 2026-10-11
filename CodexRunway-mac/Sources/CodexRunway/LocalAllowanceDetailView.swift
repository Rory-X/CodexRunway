import CodexRunwayCore
import SwiftUI

/// Explains where a locally fitted allowance came from: the rate, the token mix
/// that rate was measured over, and the individual observations behind it.
///
/// The point is auditability. An allowance recovered as a ratio is only as good as
/// the line it was fitted to, so this page shows that line, its goodness of fit, and
/// the samples — a reader can see for themselves whether to trust the number.
struct LocalAllowanceDetailView: View {
    var allowance: LocalQuotaAllowance?
    var error: String?
    var l10n: L10n

    var body: some View {
        PolishedScrollView(verticalPadding: 4) {
            if let allowance {
                VStack(alignment: .leading, spacing: 16) {
                    summary(allowance)
                    if !allowance.isReliable { reliabilityWarning }
                    rateSection(allowance)
                    consumptionSection(allowance)
                    mixSection(allowance)
                    if allowance.spansMultipleModels { multiModelNote(allowance) }
                    samplesSection(allowance)
                    methodSection(allowance)
                }
            } else if let error, !error.isEmpty {
                Text(error)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(l10n.text(.notLoaded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Summary

    private func summary(_ allowance: LocalQuotaAllowance) -> some View {
        RunwayPageSummaryRow(
            title: l10n.text(.localAllowanceRemaining),
            meta: l10n.text(.localAllowance),
            figure: remainingText(allowance))
    }

    private var reliabilityWarning: some View {
        Text(l10n.text(.localAllowanceLowConfidenceDetail))
            .font(.caption)
            .foregroundStyle(Color(nsColor: .systemOrange))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - The fitted rate

    private func rateSection(_ allowance: LocalQuotaAllowance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(l10n.text(.localAllowanceRateSection))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let perPoint = allowance.usdPerPercentPoint {
                    RunwayStatCard(
                        title: l10n.text(.localAllowancePerPercent),
                        value: QuotaEstimateFormatting.usd(perPoint),
                        color: Color(nsColor: .systemBlue))
                }
                RunwayStatCard(
                    title: l10n.text(.localAllowancePerPercentTokens),
                    value: TokenUsageHeatmapBuilder.compactTokenCount(
                        Int(allowance.tokensPerPercentPoint.rounded()),
                        language: l10n.language),
                    color: Color(nsColor: .systemIndigo))
                if let total = allowance.allowanceUSD {
                    RunwayStatCard(
                        title: l10n.text(.localAllowanceTotal),
                        value: QuotaEstimateFormatting.usd(total),
                        color: Color(nsColor: .systemGreen))
                }
                RunwayStatCard(
                    title: l10n.text(.localAllowanceFitQuality),
                    value: String(format: "R² %.3f", allowance.rSquared),
                    color: allowance.isReliable
                        ? Color(nsColor: .systemTeal)
                        : Color(nsColor: .systemOrange))
            }
            Text(String(
                format: l10n.text(.localAllowanceFitDetail),
                allowance.sampleCount,
                String(format: "%.0f", allowance.percentSpan)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Consumption

    private func consumptionSection(_ allowance: LocalQuotaAllowance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(l10n.text(.localAllowanceConsumptionSection))
            // The bar the summary card shows, with the figures it was drawn from.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                    Capsule()
                        .fill(allowance.isReliable
                            ? Color(nsColor: .systemBlue)
                            : Color(nsColor: .systemOrange))
                        .frame(width: max(1, proxy.size.width * allowance.usedFraction))
                }
            }
            .frame(height: 8)
            HStack {
                Text(String(
                    format: l10n.text(.localAllowanceUsedOfTotal),
                    String(format: "%.0f%%", allowance.usedPercent),
                    spentText(allowance)))
                Spacer()
                Text(String(
                    format: l10n.text(.localAllowanceRemainingOfTotal),
                    remainingText(allowance)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(String(
                format: l10n.text(.localAllowanceProgressBasis),
                allowance.resetsAt.formatted(date: .abbreviated, time: .shortened)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Token mix

    private func mixSection(_ allowance: LocalQuotaAllowance) -> some View {
        let breakdown = allowance.breakdown
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle(l10n.text(.localAllowanceMixSection))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let rate = breakdown.cacheHitRate {
                    RunwayStatCard(
                        title: l10n.text(.localAllowanceCacheHitRate),
                        value: String(format: "%.1f%%", rate * 100),
                        color: Color(nsColor: .systemPurple))
                }
                RunwayStatCard(
                    title: l10n.text(.localAllowanceTotalTokens),
                    value: TokenUsageHeatmapBuilder.compactTokenCount(
                        breakdown.totalTokens, language: l10n.language),
                    color: Color(nsColor: .systemBrown))
                RunwayStatCard(
                    title: l10n.text(.localAllowanceCachedInput),
                    value: TokenUsageHeatmapBuilder.compactTokenCount(
                        breakdown.cachedInputTokens, language: l10n.language),
                    color: Color(nsColor: .systemTeal))
                RunwayStatCard(
                    title: l10n.text(.localAllowanceFreshInput),
                    value: TokenUsageHeatmapBuilder.compactTokenCount(
                        breakdown.uncachedInputTokens, language: l10n.language),
                    color: Color(nsColor: .systemOrange))
                RunwayStatCard(
                    title: l10n.text(.localAllowanceOutput),
                    value: TokenUsageHeatmapBuilder.compactTokenCount(
                        breakdown.outputTokens, language: l10n.language),
                    color: Color(nsColor: .systemPink))
                if allowance.breakdown.cacheWriteInputTokens > 0 {
                    RunwayStatCard(
                        title: l10n.text(.localAllowanceCacheWrite),
                        value: TokenUsageHeatmapBuilder.compactTokenCount(
                            breakdown.cacheWriteInputTokens, language: l10n.language),
                        color: Color(nsColor: .systemRed))
                }
            }
            // The single most useful explanation of a big-token / small-dollar gap.
            if let share = breakdown.cacheShareOfTotal, let rate = breakdown.cacheHitRate {
                Text(String(
                    format: l10n.text(.localAllowanceCacheExplanation),
                    String(format: "%.1f%%", share * 100),
                    String(format: "%.1f%%", rate * 100)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func multiModelNote(_ allowance: LocalQuotaAllowance) -> some View {
        Text(String(
            format: l10n.text(.localAllowanceMultiModelNote),
            allowance.breakdown.models.joined(separator: "、")))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Observations

    private func samplesSection(_ allowance: LocalQuotaAllowance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(l10n.text(.localAllowanceSamplesSection))
            if allowance.points.isEmpty {
                Text(l10n.text(.usageAnalyticsEmpty))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                RunwayTableContainer {
                    HStack {
                        Text(l10n.text(.date)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(l10n.text(.localAllowanceUsedPercentColumn))
                            .frame(width: 74, alignment: .trailing)
                        Text(l10n.text(.localAllowanceSpentColumn))
                            .frame(width: 84, alignment: .trailing)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                } rows: {
                    // Newest first: the most recent observations are what the current
                    // remaining figure rests on.
                    ForEach(Array(allowance.points.suffix(Self.maxSampleRows).reversed().enumerated()),
                            id: \.element.id) { index, point in
                        HStack {
                            Text(point.at.formatted(date: .omitted, time: .shortened))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(format: "%.0f%%", point.percent))
                                .frame(width: 74, alignment: .trailing)
                            Text(point.cumulativeUSD.map(QuotaEstimateFormatting.usd) ?? "—")
                                .frame(width: 84, alignment: .trailing)
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .tableRowRule(isFirst: index == 0)
                    }
                }
            }
        }
    }

    /// Enough rows to show the trend without turning the page into a log dump.
    private static let maxSampleRows = 40

    // MARK: - Method

    private func methodSection(_ allowance: LocalQuotaAllowance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(l10n.text(.localAllowanceMethodSection))
            Text(l10n.text(.localAllowanceMethodDetail))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(
                format: l10n.text(.localAllowanceModelAndPricing),
                allowance.breakdown.models.joined(separator: "、"),
                allowance.pricingVersion))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    private func remainingText(_ allowance: LocalQuotaAllowance) -> String {
        if let remaining = allowance.remainingUSD {
            return QuotaEstimateFormatting.usd(remaining)
        }
        if let tokens = allowance.remainingTokens {
            return TokenUsageHeatmapBuilder.compactTokenCount(
                Int(tokens.rounded()), language: l10n.language)
        }
        return "—"
    }

    private func spentText(_ allowance: LocalQuotaAllowance) -> String {
        guard let total = allowance.allowanceUSD else {
            let spent = allowance.allowanceTokens * allowance.usedFraction
            return TokenUsageHeatmapBuilder.compactTokenCount(
                Int(spent.rounded()), language: l10n.language)
        }
        return QuotaEstimateFormatting.usd(total * allowance.usedFraction)
    }
}
