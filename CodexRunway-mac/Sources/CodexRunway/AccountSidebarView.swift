import AppKit
import CodexRunwayCore
import SwiftUI

/// Accounts list shown as a popover detail page (same navigation pattern as reset credits).
struct AccountsDetailView: View {
    @ObservedObject var model: RunwayModel
    var l10n: L10n
    var onAddAccount: () -> Void
    var onShowRelayRequests: () -> Void = {}

    @State private var accountPendingSwitch: ManagedAccount?
    @State private var accountPendingDelete: ManagedAccount?
    @State private var restartAfterSwitch = true
    @State private var dashboardTokenAccount: ManagedAccount?
    /// Account whose stored relay config is being shown.
    @State private var relayConfigAccount: ManagedAccount?
    @State private var dashboardTokenDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            PolishedScrollView(verticalPadding: 0, fadesEdges: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.sidebarAccounts.isEmpty {
                        Text(l10n.text(.accountsEmpty))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RunwaySurface.fill, in: RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius))
                    } else {
                        ForEach(model.sidebarAccounts) { account in
                            sidebarCard(for: account)
                        }
                    }
                    if let message = model.accountOperationMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    if model.pendingOAuthURL != nil {
                        oauthPendingActions
                    }
                    if let error = model.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(
            l10n.text(.accountsDeleteConfirmTitle),
            isPresented: Binding(
                get: { accountPendingDelete != nil },
                set: { if !$0 { accountPendingDelete = nil } }))
        {
            Button(l10n.text(.accountsDelete), role: .destructive) {
                if let id = accountPendingDelete?.id {
                    model.deleteAccount(id: id)
                }
                accountPendingDelete = nil
            }
            Button(l10n.text(.cancel), role: .cancel) {
                accountPendingDelete = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("\(accountPendingDelete?.resolvedDisplayName ?? "")\n\n\(l10n.text(.accountsDeleteConfirmMessage))")
        }
        .sheet(item: $relayConfigAccount) { account in
            RelayConfigDetailView(
                account: account,
                stored: model.storedRelayConfig(accountID: account.id),
                live: model.liveRelayConfig(),
                dashboardToken: model.dashboardToken(accountID: account.id),
                relayKey: model.maskedRelayKey(accountID: account.id),
                l10n: l10n,
                supportsWebSockets: model.relaySupportsWebSockets(for: account),
                onToggleWebSockets: { model.setRelaySupportsWebSockets($0, for: account) },
                onClose: { relayConfigAccount = nil })
        }
        .sheet(item: $dashboardTokenAccount) { account in
            NewAPIDashboardTokenSheet(
                account: account,
                l10n: l10n,
                draft: $dashboardTokenDraft,
                hasToken: model.hasDashboardToken(accountID: account.id),
                onSave: { token in
                    model.saveDashboardToken(token, accountID: account.id)
                    dashboardTokenDraft = ""
                    dashboardTokenAccount = nil
                },
                onRemove: {
                    model.removeDashboardToken(accountID: account.id)
                    dashboardTokenDraft = ""
                    dashboardTokenAccount = nil
                },
                onCancel: {
                    dashboardTokenDraft = ""
                    dashboardTokenAccount = nil
                })
        }
        .sheet(isPresented: Binding(
            get: { accountPendingSwitch != nil },
            set: { if !$0 { accountPendingSwitch = nil } }))
        {
            AccountSwitchConfirmSheet(
                accountName: accountPendingSwitch?.resolvedDisplayName ?? "",
                l10n: l10n,
                restartAfterSwitch: $restartAfterSwitch,
                onConfirm: {
                    if let id = accountPendingSwitch?.id {
                        model.switchAccount(id: id, restartCodex: restartAfterSwitch)
                    }
                    accountPendingSwitch = nil
                },
                onCancel: {
                    accountPendingSwitch = nil
                })
        }
    }

    /// One account card. Extracted so the `ForEach` body stays a single call: with
    /// the card's parameter list and five closures inlined, the expression exceeded
    /// what the type checker resolves in reasonable time.
    @ViewBuilder
    private func sidebarCard(for account: ManagedAccount) -> some View {
        AccountDetailCard(
            account: account,
            isActive: account.id == model.activeAccountId,
            l10n: l10n,
            isBusy: model.isSwitchingAccount,
            isRefreshing: model.isRefreshingAccountQuota(id: account.id),
            onSelect: {
                restartAfterSwitch = true
                accountPendingSwitch = account
            },
            onRefresh: {
                model.refreshAccountQuota(id: account.id)
            },
            onDelete: {
                accountPendingDelete = account
            },
            onShowRequests: {
                onShowRelayRequests()
            },
            onShowConfig: {
                relayConfigAccount = account
            },
            onStartQuotaWindow: {
                Task { await model.startQuotaWindow(
                    accountID: account.id,
                    autoStartEnabled: model.settings.preferences.autoStartsQuotaWindow) }
            },
            onReauthorize: {
                model.startReauthorization(accountID: account.id)
            },
            isReauthorizing: model.reauthorizingAccountId == account.id)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ToolbarGhostButton(
                title: l10n.text(.accountsRefreshAll),
                systemImage: "arrow.clockwise",
                isLoading: model.isRefreshingAccountQuotas)
            {
                model.refreshAllAccountQuotas()
            }
            Spacer()
            ToolbarAccentButton(title: l10n.text(.accountsAdd), systemImage: "plus", action: onAddAccount)
        }
    }

    /// Fallback controls while a browser sign-in is in flight.
    ///
    /// The window is opened automatically, but a browser that never came to the front —
    /// or a link the user closed by accident — would otherwise leave no way forward from
    /// this page.
    private var oauthPendingActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The link itself, selectable, so the sign-in can be done in a particular
            // browser profile or on another machine rather than wherever this app
            // happens to open it.
            if let url = model.pendingOAuthURL {
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(l10n.text(.accountsOAuthOpenLink)) {
                    model.openPendingOAuthURL()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(l10n.text(.accountsOAuthCopyLink)) {
                    model.copyPendingOAuthURL()
                }
                .controlSize(.small)
                Button(l10n.text(.cancel)) {
                    model.cancelOAuthLogin()
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }
}

/// Quiet toolbar action: icon + label, transparent at rest, neutral pill on hover.
struct ToolbarGhostButton: View {
    var title: String
    var systemImage: String
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var action: () -> Void

    @State private var isHovered = false

    private var inactive: Bool { isLoading || isDisabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.medium))
                }
                Text(title)
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(isHovered && !inactive ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isHovered && !inactive ? RunwaySurface.hoverNeutral : Color.clear,
                in: RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .padding(.leading, -9)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(inactive)
        .help(title)
        .accessibilityLabel(title)
        .pointingHandCursor(enabled: !inactive)
        .onHover { isHovered = $0 }
    }
}

/// Accent CTA matching the Calculate-button chassis.
struct ToolbarAccentButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            toolbarAccentLabel(title: title, systemImage: systemImage, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}

/// Accent menu trigger — same chassis as `ToolbarAccentButton`, for multi-action “Add”.
struct ToolbarAccentMenu<Content: View>: View {
    var title: String
    var systemImage: String
    var isDisabled: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var isHovered = false

    var body: some View {
        Menu {
            content()
        } label: {
            toolbarAccentLabel(title: title, systemImage: systemImage, isHovered: isHovered && !isDisabled)
        }
        .menuStyle(.borderlessButton)
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
        .pointingHandCursor(enabled: !isDisabled)
        .onHover { isHovered = $0 }
    }
}

@ViewBuilder
private func toolbarAccentLabel(title: String, systemImage: String, isHovered: Bool) -> some View {
    HStack(spacing: 5) {
        Image(systemName: systemImage)
            .font(.caption.weight(.semibold))
        Text(title)
            .font(.callout.weight(.semibold))
    }
    .foregroundStyle(Color.white)
    .padding(.horizontal, 11)
    .frame(minHeight: 26)
    .background(
        isHovered ? Color.accentColor.opacity(0.88) : Color.accentColor,
        in: RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
    .animation(.easeOut(duration: 0.12), value: isHovered)
}

/// Shared multi-account card chrome: current green wash, hover fill, hairline stroke.
struct AccountManagedCardChrome: ViewModifier {
    var isCurrent: Bool

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: RunwaySurface.radiusCard, style: .continuous)
                if isCurrent {
                    shape.fill(Color(nsColor: .systemGreen).opacity(colorScheme == .light ? 0.10 : 0.12))
                } else {
                    shape.fill(isHovered ? RunwaySurface.hoverNeutral : RunwaySurface.raised)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: RunwaySurface.radiusCard, style: .continuous)
                    .strokeBorder(cardStroke, lineWidth: 1))
            .onHover { isHovered = $0 }
    }

    private var cardStroke: Color {
        if isCurrent {
            return Color(nsColor: .systemGreen).opacity(colorScheme == .light ? 0.28 : 0.35)
        }
        return colorScheme == .dark ? RunwaySurface.hairline : Color.clear
    }
}

extension View {
    func accountManagedCardChrome(isCurrent: Bool) -> some View {
        modifier(AccountManagedCardChrome(isCurrent: isCurrent))
    }
}

/// Compact quota meter row used by multi-account cards.
struct AccountMiniMeterRow: View {
    var title: String
    var remaining: Int
    var used: Int
    /// When set, shown instead of the default “N% left” trailing label.
    var trailingValue: String? = nil
    var resetsAt: Date?
    var l10n: L10n
    var isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(trailingValue ?? "\(remaining)% \(l10n.text(.left))")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(
                        trailingValue == nil
                            ? RunwayProgressBar.textColor(for: QuotaMeter.health(forUsedPercent: used))
                            : Color.secondary)
            }
            GeometryReader { proxy in
                let fill = max(3, proxy.size.width * CGFloat(remaining) / 100)
                ZStack(alignment: .leading) {
                    Capsule().fill(meterTrack)
                    Capsule()
                        .fill(barColor)
                        .frame(width: fill)
                }
            }
            .frame(height: 5)
            if trailingValue != nil {
                Text("\(remaining)% \(l10n.text(.left))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let resetsAt {
                NextResetCountdownLabel(resetsAt: resetsAt, l10n: l10n)
            }
        }
    }

    private var barColor: Color {
        switch QuotaMeter.health(forUsedPercent: used) {
        case .green: return Color(nsColor: .systemGreen)
        case .yellow: return Color(nsColor: .systemOrange)
        case .red: return Color(nsColor: .systemRed)
        }
    }

    private var meterTrack: Color {
        if isCurrent {
            return Color(nsColor: .systemGreen).opacity(0.12)
        }
        return RunwaySurface.sunken
    }
}

enum AccountCardStatus {
    static func warning(for account: ManagedAccount, l10n: L10n) -> String? {
        if account.requiresReauth { return l10n.text(.accountsNeedsReauth) }
        if let error = account.lastError {
            return AccountErrorCode.localizedText(for: error, l10n: l10n) ?? error
        }
        return nil
    }
}

private struct AccountDetailCard: View {
    var account: ManagedAccount
    var isActive: Bool
    var l10n: L10n
    var isBusy: Bool
    var isRefreshing: Bool
    var onSelect: () -> Void
    var onRefresh: () -> Void
    var onDelete: () -> Void
    var onConfigureToken: () -> Void = {}
    var onShowRequests: () -> Void = {}
    var onShowConfig: () -> Void = {}
    var onStartQuotaWindow: () -> Void = {}
    var onReauthorize: () -> Void = {}
    /// True while this account's browser sign-in is running.
    var isReauthorizing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            if isReauthorizing {
                statusLine(l10n.text(.accountsReauthorizeInProgress), color: Color(nsColor: .systemBlue))
            } else if let warning = AccountCardStatus.warning(for: account, l10n: l10n) {
                statusLine(warning, color: account.requiresReauth
                    ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange))
                // The repair sits beside the warning rather than only in the ⋯ menu,
                // because this is the one state the user has to act on.
                if account.requiresReauth {
                    reauthorizeButton
                }
            }
            quotaBlock
        }
        .accountManagedCardChrome(isCurrent: isActive)
    }

    private var reauthorizeButton: some View {
        Button(action: onReauthorize) {
            Label(l10n.text(.accountsReauthorize), systemImage: "person.badge.key")
                .font(.caption)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(isBusy || isReauthorizing)
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.resolvedDisplayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if isActive {
                        CurrentAccountTag(l10n: l10n)
                    }
                    SubscriptionTierTag(tier: account.subscriptionTier, l10n: l10n)
                    if let email = account.email, email != account.resolvedDisplayName {
                        Text(email)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                AccountIdentityDetailsLabel(account: account, l10n: l10n)
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                AccountIconActionButton(
                    title: isActive ? l10n.text(.accountsIsCurrentLogin) : l10n.text(.accountsMakeCurrent),
                    systemImage: isActive ? "checkmark.circle.fill" : "checkmark.circle",
                    isDisabled: isActive || isBusy || isRefreshing,
                    tone: isActive ? .current : .normal,
                    action: onSelect)
                AccountIconActionButton(
                    title: l10n.text(.refresh),
                    systemImage: "arrow.clockwise",
                    isDisabled: isRefreshing,
                    isLoading: isRefreshing,
                    tone: .normal,
                    action: onRefresh)
                Menu {
                    if account.authMode == .apiKey {
                        Button(action: onConfigureToken) {
                            Label(l10n.text(.newAPIDashboardToken), systemImage: "key")
                        }
                        Button(action: onShowRequests) {
                            Label(l10n.text(.newAPIRecentRequests), systemImage: "list.bullet")
                        }
                        Button(action: onShowConfig) {
                            Label(l10n.text(.relayConfigDetailTitle), systemImage: "gearshape.2")
                        }
                        Divider()
                    }
                    // Only a subscription account can be repaired by signing in again.
                    if account.authMode == .oauth {
                        Button(action: onReauthorize) {
                            Label(l10n.text(.accountsReauthorize), systemImage: "person.badge.key")
                        }
                        .disabled(isBusy || isReauthorizing)
                        Divider()
                    }
                    // Only a subscription account has a 5-hour window to open.
                    if account.authMode == .oauth {
                        Button(action: onStartQuotaWindow) {
                            Label(l10n.text(.quotaWindowStartNow), systemImage: "timer")
                        }
                        Divider()
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label(l10n.text(.accountsDelete), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isBusy || isRefreshing)
                .help(l10n.text(.accountsActions))
                .accessibilityLabel(l10n.text(.accountsActions))
            }
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var quotaBlock: some View {
        if let relay = account.cachedQuota?.newAPI {
            NewAPIBalanceBlock(
                balance: relay,
                l10n: l10n,
                isCurrent: isActive)
        } else if let quota = account.cachedQuota {
            // Titles follow the same windowMinutes / named-window rules as the main popover.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(quota.meterRows()) { row in
                    AccountMiniMeterRow(
                        title: row.title(l10n: l10n),
                        remaining: row.remainingPercent,
                        used: row.usedPercent,
                        resetsAt: row.resetsAt,
                        l10n: l10n,
                        isCurrent: isActive)
                }
            }
        } else if account.authMode == .apiKey {
            // Nothing to report: no balance, and no way to fetch one. An instruction
            // to add a token would be the wrong message when one is already stored,
            // and either way it is not something the user can act on from here. The
            // `API` badge in the card header already says what this account is.
            EmptyView()
        } else {
            Text(l10n.text(.notLoaded))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Relay balance and usage for a New API account.
///
/// A relay account has no 5h/weekly quota windows, so this replaces the meter
/// rows rather than sitting beside them. The bar shows consumed share of the
/// grant when the relay reports both halves; a relay with no spend limit shows
/// the figure without a bar, because a percentage would be meaningless.
struct NewAPIBalanceBlock: View {
    var balance: CachedNewAPIBalance
    var l10n: L10n
    var isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(l10n.text(.newAPIBalance))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let remaining = balance.remainingUSD {
                    Text(NewAPIBalanceBlock.money(remaining))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                    if let total = balance.totalUSD {
                        Text("/ " + NewAPIBalanceBlock.money(total))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else if balance.keyIsUnlimited {
                    // The relay reports no spend limit, so a remaining figure would
                    // be meaningless; say so instead of showing a dash.
                    Text(l10n.text(.newAPIBalanceUnlimited))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(l10n.text(.newAPIUsageUnavailable))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let fraction = balance.usedFraction {
                // Filled like the Codex meters: the bar shows what is *left*, so the
                // two card styles read the same way.
                let remainingFraction = min(max(1 - fraction, 0), 1)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(NewAPIBalancePresenter.barColor(remainingFraction: remainingFraction))
                            .frame(width: max(3, proxy.size.width * CGFloat(remainingFraction)))
                    }
                }
                .frame(height: 5)
            }

            HStack(spacing: 10) {
                stat(l10n.text(.newAPITodayCost), balance.todayCostUSD.map(NewAPIBalanceBlock.money) ?? "—")
                stat(l10n.text(.newAPITodayTokens), balance.todayTokens.map(NewAPIBalanceBlock.compact) ?? "—")
                stat(l10n.text(.newAPISevenDayTokens), balance.sevenDayTokens.map(NewAPIBalanceBlock.compact) ?? "—")
            }

            if !balance.keyIsUnlimited, let keyUsed = balance.keyUsedUSD {
                // The key's own spend is useful beside the account total: they differ
                // whenever the relay is shared with other keys.
                Text("\(l10n.text(.newAPIRequests)) \(balance.requestCount.map(String.init) ?? "—") · \(NewAPIBalanceBlock.money(keyUsed))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.caption.weight(.medium)).monospacedDigit().lineLimit(1)
        }
    }


    static func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = value < 10 ? 2 : 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    static func compact(_ tokens: Int) -> String {
        TokenUsageHeatmapBuilder.compactTokenCount(tokens, language: .english)
    }
}

/// Icon button with the same hover treatment as the main popover header actions.
/// Shared by multi-account cards.
struct AccountIconActionButton: View {
    enum Tone {
        case normal
        case current
    }

    var title: String
    var systemImage: String
    var isDisabled: Bool = false
    var isLoading: Bool = false
    var tone: Tone = .normal
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: systemImage)
                        .font(.body)
                        .frame(width: 14, height: 14)
                }
            }
            .foregroundStyle(iconColor)
            .frame(width: 28, height: 24)
            .background(buttonBackground, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovering in
            // Keep hover feedback for disabled "current" so the tooltip affordance is clear.
            isHovered = hovering && !isLoading && (tone == .current || !isDisabled)
        }
    }

    private var iconColor: Color {
        if isLoading { return Color.secondary }
        switch tone {
        case .current:
            return Color(nsColor: .systemGreen)
        case .normal:
            if isDisabled { return Color.secondary }
            return isHovered ? Color.accentColor : Color.primary
        }
    }

    private var buttonBackground: Color {
        if tone == .current {
            return isHovered
                ? Color(nsColor: .systemGreen).opacity(0.16)
                : Color(nsColor: .systemGreen).opacity(0.10)
        }
        if isDisabled || isLoading { return Color.clear }
        return isHovered ? RunwaySurface.hoverAccent : Color.clear
    }
}

/// Live “next reset in …” countdown used by multi-account cards and settings rows.
struct NextResetCountdownLabel: View {
    var resetsAt: Date
    var l10n: L10n
    var font: Font = .caption2
    /// How often the relative duration re-renders (seconds).
    var refreshInterval: TimeInterval = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: refreshInterval)) { context in
            Text("\(l10n.text(.nextResetIn))\(DurationFormatter.localized(resetsAt.timeIntervalSince(context.date), language: l10n.language))")
                .font(font)
                .foregroundStyle(.secondary)
        }
    }
}

/// Shared plan tag for Codex accounts UI.
struct SubscriptionTierTag: View {
    var tier: CodexSubscriptionTier
    var l10n: L10n

    var body: some View {
        SubscriptionTierBadge(
            tier: tier,
            label: SubscriptionTierBadge.localizedTitle(for: tier, l10n: l10n),
            horizontalPadding: 5,
            verticalPadding: 1)
    }
}

/// Workspace name plus separate user/workspace identifiers for managed Codex credentials.
struct AccountIdentityDetailsLabel: View {
    var account: ManagedAccount
    var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let userId = account.identityMarkerUserId {
                identityRow(
                    label: l10n.text(.accountsUserIdLabel),
                    value: userId,
                    monospaced: true)
            }
            if account.displaysWorkspaceIdentity,
               let workspaceId = account.identityMarkerWorkspaceId
            {
                identityRow(
                    label: l10n.text(.accountsWorkspaceIdLabel),
                    value: workspaceId,
                    monospaced: true)
                if let workspaceName = normalizedWorkspaceName {
                    identityRow(
                        label: l10n.text(.accountsWorkspaceNameLabel),
                        value: workspaceName,
                        monospaced: false)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var normalizedWorkspaceName: String? {
        guard let name = account.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return name
    }

    private func identityRow(
        label: String,
        value: String,
        monospaced: Bool) -> some View
    {
        (Text(label).font(.caption2)
            + Text(value).font(monospaced ? .caption2.monospaced() : .caption2))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help("\(label)\(value)")
    }
}



/// Sets or clears the relay dashboard token for an existing account.
///
/// Shared by the accounts list and the settings pane so both entry points behave
/// identically.
struct NewAPIDashboardTokenSheet: View {
    var account: ManagedAccount
    var l10n: L10n
    @Binding var draft: String
    var hasToken: Bool
    var onSave: (String) -> Void
    var onRemove: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text(.newAPIDashboardToken)).font(.headline)
            Text(l10n.text(.newAPIDashboardTokenHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PasteableTextEditor(text: $draft, monospaced: true)
                .frame(minHeight: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))

            HStack {
                if hasToken {
                    Button(l10n.text(.newAPIDashboardTokenRemove), action: onRemove)
                }
                Spacer()
                Button(l10n.text(.cancel), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(l10n.text(.ok)) { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
