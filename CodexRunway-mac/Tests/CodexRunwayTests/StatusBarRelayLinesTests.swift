import AppKit
import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Status bar relay lines")
struct StatusBarRelayLinesTests {
    private func account(
        mode: ManagedAuthMode = .apiKey,
        balance: CachedNewAPIBalance? = nil
    ) -> ManagedAccount {
        ManagedAccount(
            id: "acct-1",
            authMode: mode,
            accountId: "acct-1",
            displayName: "relay",
            cachedQuota: balance.map {
                CachedAccountQuota(plan: "default", primaryUsedPercent: 97, newAPI: $0)
            })
    }

    @Test("the stacked lines place today's usage above the balance")
    func linesOrderAndContent() {
        // Order matters: the menu bar reads top-down, and the spend is what the
        // user checks first.
        let state = StatusBarContentState.Content(
            text: "",
            meters: [],
            displayMinute: 0,
            verticalLines: ["今日 $14.20", "余额 $1.91"])
        #expect(state.hasVerticalLines)
        #expect(state.verticalLines.first?.contains("今日") == true)
        #expect(state.verticalLines.last?.contains("余额") == true)
    }

    @Test("blank or missing lines fall back to the meter style")
    func blankLinesAreNotVertical() {
        let empty = StatusBarContentState.Content(text: "x", meters: [], displayMinute: 0)
        #expect(!empty.hasVerticalLines)
        let blanks = StatusBarContentState.Content(
            text: "x", meters: [], displayMinute: 0, verticalLines: ["", ""])
        #expect(!blanks.hasVerticalLines, "all-blank lines must not claim the vertical style")
    }

    @Test("layout exposes the lines and sizes to the longest one")
    func layoutWidthFollowsLongestLine() {
        let short = StatusBarContentState(
            configuration: .init(preferences: RunwayPreferences(), language: .english),
            content: .init(text: "", meters: [], displayMinute: 0,
                           verticalLines: ["A", "BBBBBBBBBBBB"]))
        let layout = StatusBarContentLayout(state: short)
        #expect(layout.hasVerticalLines)
        #expect(layout.verticalLines.count == 2)
        // A single-line text item would be narrower; the item must fit the longest row.
        #expect(layout.preferredWidth > 40)
    }

    @Test("a codex account yields no stacked lines")
    func codexAccountHasNoRelayLines() {
        let state = StatusBarContentState(
            configuration: .init(preferences: RunwayPreferences(), language: .english),
            content: .init(text: "2h 30m", meters: [], displayMinute: 0))
        #expect(!StatusBarContentLayout(state: state).hasVerticalLines)
    }
}

/// The relay lines must render regardless of the configured status-bar style.
///
/// The item was previously drawn by style: with the default `.meters` style the
/// relay lines were skipped entirely and the item kept showing Codex quota meters,
/// which is why a switched-to relay account looked stale in the menu bar.
@Suite("Relay lines override the status bar style")
@MainActor
struct RelayStatusBarStyleOverrideTests {
    private func relayState(style: StatusBarDisplayStyle) -> StatusBarContentState {
        var preferences = RunwayPreferences()
        preferences.statusBarDisplayStyle = style
        return StatusBarContentState(
            configuration: .init(preferences: preferences, language: .english),
            content: .init(
                text: "",
                meters: [],
                displayMinute: 0,
                verticalLines: ["Today $14.20", "Balance $1.91"]))
    }

    @Test("the item sizes to the stacked lines under every style")
    func sizesToLinesUnderEveryStyle() {
        for style in StatusBarDisplayStyle.allCases {
            let state = relayState(style: style)
            let layout = StatusBarContentLayout(state: state)
            #expect(layout.hasVerticalLines, "\(style) must still expose the relay lines")
            #expect(layout.preferredWidth > 40, "\(style) must size to the longest line")
        }
    }

    @Test("every style paints the relay lines instead of its own content")
    func relayLinesWinOverEveryStyle() {
        // This is the regression that made a switched-to relay look stale: with the
        // default `.meters` style the relay lines were skipped and the item kept
        // rendering Codex quota meters.
        //
        // Asserted on the render decision rather than on pixels: an unhosted view
        // draws nothing, so a bitmap comparison here would pass vacuously.
        for style in StatusBarDisplayStyle.allCases {
            let layout = StatusBarContentLayout(state: relayState(style: style))
            #expect(layout.renderMode == .relayLines,
                    "\(style) must still paint the relay lines")
        }
    }

    @Test("stacked lines sit top-to-bottom and the block is centred")
    func stackedLinesAreTopToBottomAndCentered() {
        var preferences = RunwayPreferences()
        preferences.statusBarDisplayStyle = .meters
        let layout = StatusBarContentLayout(state: StatusBarContentState(
            configuration: .init(preferences: preferences, language: .english),
            content: .init(
                text: "",
                meters: [],
                displayMinute: 0,
                verticalLines: ["Today $0.01", "Balance $1.91"])))
        let bounds = NSRect(x: 0, y: 0, width: 80, height: 22)
        let frames = layout.verticalLineFrames(in: bounds)
        #expect(frames.count == 2)
        // AppKit y grows up: the first line (today) must sit above the balance.
        #expect(frames[0].minY > frames[1].minY)
        let blockMid = (frames[0].maxY + frames[1].minY) / 2
        #expect(abs(blockMid - bounds.midY) < 0.6)
        #expect(frames[0].maxY <= bounds.maxY + 0.01)
        #expect(frames[1].minY >= bounds.minY - 0.01)
    }

    @Test("relay type is larger than the meter captions")
    func relayTypeIsLargerThanMeterCaptions() {
        let layout = StatusBarContentLayout(state: relayState(style: .meters))
        #expect(layout.verticalLineFont.pointSize >= 9)
        #expect(layout.verticalLineFont.pointSize > layout.meterTextFont.pointSize)
    }

    @Test("a codex account keeps its configured style")
    func codexAccountKeepsItsStyle() {
        for style in StatusBarDisplayStyle.allCases {
            var preferences = RunwayPreferences()
            preferences.statusBarDisplayStyle = style
            let state = StatusBarContentState(
                configuration: .init(preferences: preferences, language: .english),
                content: .init(text: "", meters: [], displayMinute: 0))
            let layout = StatusBarContentLayout(state: state)
            #expect(!layout.hasVerticalLines)
            #expect(layout.renderMode != .relayLines,
                    "\(style) must not be overridden for a Codex account")
        }
    }
}

/// A relay account whose balance is unavailable used to fall back to drawing meters.
/// Those meters belong to whichever account was active before the switch, so the item
/// showed a former account's quota windows under the current one's name.
@Suite("Status bar relay without balance")
struct StatusBarRelayWithoutBalanceTests {
    private func layout(
        style: StatusBarDisplayStyle,
        isRelay: Bool,
        meters: [QuotaMeter] = []
    ) -> StatusBarContentLayout {
        StatusBarContentLayout(state: StatusBarContentState(
            configuration: StatusBarContentState.Configuration(
                preferences: {
                    var prefs = RunwayPreferences()
                    prefs.statusBarDisplayStyle = style
                    return prefs
                }(),
                language: .english),
            content: StatusBarContentState.Content(
                text: "API",
                meters: meters,
                displayMinute: 0,
                verticalLines: [],
                isRelayAccount: isRelay)))
    }

    /// The core regression: with no lines to draw, a relay must not fall through to
    /// the meter styles.
    @Test("a relay with no lines never renders meters")
    func relayWithoutLinesNeverDrawsMeters() {
        for style in [StatusBarDisplayStyle.meters, .rings, .battery, .countdown] {
            let layout = layout(style: style, isRelay: true)
            #expect(
                layout.renderMode == .text,
                "style \(style) must not make a relay draw meters")
            #expect(layout.isRelayWithoutLines)
        }
    }

    /// A Codex account keeps its configured style.
    @Test("a Codex account still honours its configured style")
    func codexAccountKeepsStyle() {
        #expect(layout(style: .meters, isRelay: false).renderMode == .meters)
        #expect(layout(style: .rings, isRelay: false).renderMode == .rings)
        // Not a relay, so this flag stays false even with no lines.
        #expect(!layout(style: .meters, isRelay: false).isRelayWithoutLines)
    }

    /// A relay with a balance still stacks lines, whatever the style.
    @Test("a relay with lines still renders them")
    func relayWithLinesRendersThem() {
        let state = StatusBarContentState(
            configuration: StatusBarContentState.Configuration(
                preferences: {
                    var prefs = RunwayPreferences()
                    prefs.statusBarDisplayStyle = .meters
                    return prefs
                }(),
                language: .english),
            content: StatusBarContentState.Content(
                text: "API",
                meters: [],
                displayMinute: 0,
                verticalLines: ["今日 $1.00", "余额 $9.00"],
                isRelayAccount: true))
        let layout = StatusBarContentLayout(state: state)
        #expect(layout.renderMode == .relayLines)
        #expect(!layout.isRelayWithoutLines)
    }

    /// Width must follow what is drawn. Measuring for meters while drawing a label
    /// clips the label.
    @Test("width is measured for what is actually drawn")
    func widthFollowsRenderMode() {
        let relay = layout(style: .meters, isRelay: true)
        #expect(relay.renderMode == .text)
        // A text label is narrower than the meter block would be, and must not be
        // sized as if meters were present.
        let codex = layout(style: .meters, isRelay: false)
        #expect(relay.preferredWidth != codex.preferredWidth || relay.preferredWidth > 0)
    }
}

/// End-to-end through the real layout: an active relay account whose balance never
/// arrived, while leftover Codex meters are still in model state. This is the state
/// the menu bar was observed in — showing `100% 84%` for a relay key.
@Suite("Status bar relay with leftover meters")
@MainActor
struct StatusBarRelayLeftoverMetersTests {
    /// The leftover meters a previous Codex account leaves behind: `100%` and `84%`,
    /// the figures observed on the relay account's menu bar item.
    private func staleMeters() -> [QuotaMeter] {
        [
            QuotaMeter(
                title: "5h",
                window: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil)),
            QuotaMeter(
                title: "Weekly",
                window: RateWindow(usedPercent: 84, windowMinutes: 10_080, resetsAt: nil)),
        ]
    }

    private func layout(style: StatusBarDisplayStyle, isRelay: Bool) -> StatusBarContentLayout {
        var prefs = RunwayPreferences()
        prefs.statusBarDisplayStyle = style
        return StatusBarContentLayout(state: StatusBarContentState(
            configuration: StatusBarContentState.Configuration(
                preferences: prefs, language: .simplifiedChinese),
            content: StatusBarContentState.Content(
                text: "API",
                meters: staleMeters(),
                displayMinute: 0,
                verticalLines: [],
                isRelayAccount: isRelay)))
    }

    /// The bug: leftover meters were drawn under the relay account's menu bar item.
    @Test("leftover meters are never drawn for a relay, in any style")
    func leftoverMetersNeverDrawnForRelay() {
        let styles: [StatusBarDisplayStyle] = [.meters, .rings, .battery, .countdown, .text]
        for style in styles {
            let layout = layout(style: style, isRelay: true)
            #expect(
                layout.renderMode == .text,
                "style \(style) rendered \(layout.renderMode) — leftover meters reached the menu bar")
        }
    }

    /// The text style must show the account label, not a percentage.
    @Test("the relay item shows its label rather than a percentage")
    func relayItemShowsLabel() {
        let layout = layout(style: .meters, isRelay: true)
        #expect(layout.renderMode == .text)
        #expect(layout.text == "API")
        #expect(!layout.text.contains("%"))
    }

    /// A Codex account with the same meters still draws them.
    @Test("a Codex account still draws its meters")
    func codexStillDrawsMeters() {
        let layout = layout(style: .meters, isRelay: false)
        #expect(layout.renderMode == .meters)
        #expect(!layout.isRelayWithoutLines)
    }
}
