import AppKit
import CodexRunwayCore

struct StatusBarContentState: Equatable {
    struct Configuration: Equatable {
        let style: StatusBarDisplayStyle
        let metersDetailStyle: StatusBarMetersDetailStyle
        let batteryScope: StatusBarBatteryScope
        let batteryDetailStyle: StatusBarBatteryDetailStyle
        let language: ResolvedLanguage

        init(preferences: RunwayPreferences, language: ResolvedLanguage) {
            style = preferences.statusBarDisplayStyle
            metersDetailStyle = preferences.statusBarMetersDetailStyle
            batteryScope = preferences.statusBarBatteryScope
            batteryDetailStyle = preferences.statusBarBatteryDetailStyle
            self.language = language
        }
    }

    struct Content: Equatable {
        let text: String
        let meters: [QuotaMeter]
        let displayMinute: Int
        /// Two short lines stacked vertically, used for relay accounts. Empty for
        /// Codex accounts, which draw meters instead.
        var verticalLines: [String] = []
        /// True when the active account is a relay key.
        ///
        /// Carried separately from `verticalLines` because a relay with no readable
        /// balance produces no lines — and without this flag that situation is
        /// indistinguishable from a Codex account, so the item falls back to drawing
        /// meters that belong to whichever account was active before.
        var isRelayAccount: Bool = false

        var now: Date {
            Date(timeIntervalSince1970: TimeInterval(displayMinute * 60))
        }

        var hasVerticalLines: Bool {
            !verticalLines.isEmpty && verticalLines.contains { !$0.isEmpty }
        }
    }

    let configuration: Configuration
    let content: Content

    static let placeholder = StatusBarContentState(
        configuration: Configuration(
            preferences: RunwayPreferences(),
            language: .english),
        content: Content(text: "", meters: [], displayMinute: 0))
}

struct StatusBarContentLayout {
    let style: StatusBarDisplayStyle
    let metersDetailStyle: StatusBarMetersDetailStyle
    /// Stacked lines for relay accounts (currently: today's usage and balance).
    let verticalLines: [String]
    /// True when the active account is a relay key, whatever it can display.
    let isRelayAccount: Bool
    let batteryScope: StatusBarBatteryScope
    let batteryDetailStyle: StatusBarBatteryDetailStyle
    let language: ResolvedLanguage
    let text: String
    let meters: [QuotaMeter]
    let now: Date

    init(state: StatusBarContentState) {
        style = state.configuration.style
        metersDetailStyle = state.configuration.metersDetailStyle
        batteryScope = state.configuration.batteryScope
        batteryDetailStyle = state.configuration.batteryDetailStyle
        language = state.configuration.language
        text = state.content.text
        meters = state.content.meters
        now = state.content.now
        verticalLines = state.content.hasVerticalLines ? state.content.verticalLines : []
        isRelayAccount = state.content.isRelayAccount
    }

    var hasVerticalLines: Bool { !verticalLines.isEmpty }

    /// A relay account with nothing to stack, so the item shows its label instead.
    var isRelayWithoutLines: Bool { isRelayAccount && !hasVerticalLines }

    /// What the view should actually paint.
    ///
    /// Pulled out of the view so the choice is testable: the relay-override rule is
    /// a decision about content, not about drawing.
    enum RenderMode: Equatable {
        case relayLines
        case meters
        case countdown
        case battery
        case rings
        case text
    }

    /// Relay accounts never paint meters, whatever the configured style.
    ///
    /// The meter styles render Codex quota windows, which a relay does not have. When
    /// its balance is unavailable there are no lines to draw either, and the item must
    /// still not fall back to meters: those would be the previous account's numbers,
    /// left over from before the switch.
    var renderMode: RenderMode {
        if hasVerticalLines { return .relayLines }
        if isRelayWithoutLines { return .text }
        switch style {
        case .meters: return .meters
        case .countdown: return .countdown
        case .battery: return .battery
        case .rings: return .rings
        case .text: return .text
        }
    }

    var renderPlan: StatusBarRenderPlan {
        StatusBarRenderPlan.make(style: style, batteryScope: batteryScope, meters: meters)
    }

    /// Natural height of one stacked line (ascender through descender).
    ///
    /// Shared by the width calculation and the drawing code so the two cannot
    /// disagree about how much vertical room the block needs. The extra point
    /// that used to sit between rows pushed two 9pt lines past the 22pt bar.
    var verticalLineHeight: CGFloat {
        let font = verticalLineFont
        return font.ascender - font.descender
    }

    /// AppKit frames (origin bottom-left) for the stacked lines, first line at the top.
    ///
    /// The whole block is centred on `bounds.midY`. AppKit's y grows up, so the
    /// first line has the higher `minY`. Drawing incrementally *upward* would
    /// invert the order the caller passed in.
    func verticalLineFrames(in bounds: NSRect) -> [NSRect] {
        let lines = verticalLines.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let available = bounds.height / CGFloat(lines.count)
        let lineHeight = min(verticalLineHeight, available)
        let total = lineHeight * CGFloat(lines.count)
        var top = bounds.midY + total / 2
        return lines.map { _ in
            top -= lineHeight
            return NSRect(x: bounds.minX, y: top, width: bounds.width, height: lineHeight)
        }
    }

    var preferredWidth: CGFloat {
        // Sized from `renderMode`, not from the configured style: the two must agree,
        // or a relay account whose style is e.g. `.meters` would be measured for
        // meters while drawing a text label, and the label would be clipped.
        switch renderMode {
        case .relayLines:
            return max(24, verticalLines
                .map { textWidth($0, font: verticalLineFont) }
                .max() ?? 0) + 10
        case .text:
            return contentWidth(textColumnWidths, gap: 4)
        case .countdown:
            guard renderPlan.meters.count > 1 else {
                return min(180, max(42, textWidth(text, font: countdownFont) + 14))
            }
            return totalWidth(countdownColumnWidths, gap: 2)
        case .battery:
            guard let onlyMeter = renderPlan.meters.count == 1 ? renderPlan.meters.first : nil else {
                return renderPlan.meters.isEmpty ? 72 : totalWidth(batteryColumnWidths, gap: 5)
            }
            // Elongated iOS-style body + terminal + padding around the center label.
            return min(150, max(72, textWidth(batteryDetail(for: onlyMeter), font: batteryFont) + 32))
        case .meters:
            return renderPlan.meters.isEmpty ? 70 : contentWidth(meterColumnWidths, gap: 6)
        case .rings:
            return CGFloat(max(1, renderPlan.meters.count) * 24 + 4)
        }
    }

    var countdownFont: NSFont {
        .systemFont(ofSize: 14, weight: .semibold)
    }

    /// Font for stacked status-bar lines.
    ///
    /// Sized to the usable height of the menu bar: 9pt leaves two rows with a
    /// little breathing room, where 8pt read as noticeably smaller than the
    /// neighbouring system items.
    var verticalLineFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    }

    var textFont: NSFont {
        .systemFont(ofSize: 14, weight: .semibold)
    }

    var countdownItemFont: NSFont {
        .systemFont(ofSize: 10, weight: .semibold)
    }

    var batteryFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    }

    var smallBatteryFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 7, weight: .semibold)
    }

    var meterTextFont: NSFont {
        .systemFont(ofSize: 8.5, weight: .semibold)
    }

    var meterBarWidth: CGFloat {
        40
    }

    var meterTextGap: CGFloat {
        4
    }

    var ringFont: NSFont {
        .systemFont(ofSize: 6, weight: .bold)
    }

    var countdownColumnWidths: [CGFloat] {
        renderPlan.meters.map {
            min(112, max(42, textWidth(countdownCaption(for: $0), font: countdownItemFont) + 10))
        }
    }

    var textCaptions: [String] {
        let meters = renderPlan.meters
        return meters.isEmpty
            ? [ringText(for: nil)]
            : meters.map { "\(ringText(for: $0))%" }
    }

    var textColumnWidths: [CGFloat] {
        textCaptions.map { max(24, textWidth($0, font: textFont) + 4) }
    }

    var batteryColumnWidths: [CGFloat] {
        renderPlan.columns.map { column in
            let maximumTextWidth = column.map {
                textWidth(batteryCaption(for: $0), font: smallBatteryFont)
            }.max() ?? 0
            // Extra room for terminal nub and shell insets.
            return min(156, max(92, maximumTextWidth + 18))
        }
    }

    var meterColumnWidths: [CGFloat] {
        renderPlan.columns.map { column in
            let maximumContentWidth = column.map { meterContentWidth(for: $0) }.max() ?? 0
            return min(166, max(64, maximumContentWidth))
        }
    }

    func meterContentWidth(for meter: QuotaMeter) -> CGFloat {
        meterBarWidth
            + meterTextGap
            + textWidth(meterCaption(for: meter), font: meterTextFont)
    }

    func countdownCaption(for meter: QuotaMeter) -> String {
        if meter.source == .modelSpecific {
            return "\(resetCountdown(for: meter)) \(meter.title)"
        }
        return "\(meter.title) \(resetCountdown(for: meter))"
    }

    func batteryCaption(for meter: QuotaMeter) -> String {
        if meter.source == .modelSpecific {
            return "\(batteryDetail(for: meter)) \(meter.title)"
        }
        return "\(meter.title) \(batteryDetail(for: meter))"
    }

    func meterCaption(for meter: QuotaMeter) -> String {
        if meter.source == .modelSpecific {
            return "\(meterDetail(for: meter)) \(meter.title)"
        }
        return "\(meter.title) \(meterDetail(for: meter))"
    }

    func ringText(for meter: QuotaMeter?) -> String {
        meter.map { "\($0.remainingPercent)" } ?? "--"
    }

    func batteryDetail(for meter: QuotaMeter) -> String {
        switch batteryDetailStyle {
        case .countdown:
            return resetCountdown(for: meter)
        case .remainingPercent:
            return "\(meter.remainingPercent)%"
        }
    }

    func columnFrames(widths: [CGFloat], gap: CGFloat, in bounds: NSRect) -> [NSRect] {
        let contentWidth = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * gap
        var x = bounds.midX - contentWidth / 2
        return widths.map { width in
            defer { x += width + gap }
            return NSRect(x: x, y: bounds.minY, width: width, height: bounds.height)
        }
    }

    func rowFrames(
        count: Int,
        in rect: NSRect,
        height: CGFloat,
        gap: CGFloat = 0)
        -> [NSRect]
    {
        let totalHeight = CGFloat(count) * height + CGFloat(max(0, count - 1)) * gap
        let bottom = rect.midY - totalHeight / 2
        return (0..<count).map { index in
            let reverseIndex = count - index - 1
            let y = bottom + CGFloat(reverseIndex) * (height + gap)
            return NSRect(x: rect.minX, y: y, width: rect.width, height: height)
        }
    }

    private func meterDetail(for meter: QuotaMeter) -> String {
        switch metersDetailStyle {
        case .remainingPercent:
            return "\(meter.remainingPercent)%"
        case .resetTime:
            return meter.resetsAt.map { ResetLabelFormatter.shortLabel(for: $0, language: language) } ?? "--"
        case .both:
            let reset = meter.resetsAt.map { ResetLabelFormatter.shortLabel(for: $0, language: language) } ?? "--"
            return "\(meter.remainingPercent)% · \(reset)"
        }
    }

    private func resetCountdown(for meter: QuotaMeter) -> String {
        meter.resetsAt.map {
            DurationFormatter.localized($0.timeIntervalSince(now), language: language, includeSeconds: false)
        } ?? "--"
    }

    private func totalWidth(_ widths: [CGFloat], gap: CGFloat) -> CGFloat {
        contentWidth(widths, gap: gap) + 8
    }

    private func contentWidth(_ widths: [CGFloat], gap: CGFloat) -> CGFloat {
        widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * gap
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        text.size(withAttributes: [.font: font]).width
    }
}
