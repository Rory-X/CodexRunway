import AppKit
import CodexRunwayCore
import SwiftUI
import UniformTypeIdentifiers

struct AccountsSettingsPane: View {
    @ObservedObject var model: RunwayModel
    var l10n: L10n

    @State private var showPasteSheet = false
    @State private var showAPIKeySheet = false
    @State private var apiKeyBaseURL = ""
    @State private var apiKeyDashboardToken = ""
    @State private var dashboardTokenAccount: ManagedAccount?
    @State private var dashboardTokenDraft = ""
    @State private var pasteText = ""
    @State private var apiKeyText = ""
    @State private var pasteSheetError: String?
    @State private var isImportingPaste = false
    @State private var accountPendingDelete: ManagedAccount?
    @State private var accountPendingSwitch: ManagedAccount?
    @State private var restartAfterSwitch = true
    @State private var editingAliasId: String?
    @State private var aliasDraft = ""

    @State private var showExportSheet = false
    @State private var exportSelectedIDs: Set<String> = []
    @State private var isExporting = false

    @State private var showImportPreviewSheet = false
    @State private var importSelectedIDs: Set<String> = []
    @State private var isImportingTransfer = false
    @State private var codexImportCandidates: [CodexAccountImportCandidate] = []
    @State private var importPreviewItems: [AccountTransferPreviewItem] = []
    @State private var importPreviewFailures: [String] = []

    var body: some View {
        PreferencesPane(remasureToken: l10n.language) {
            SettingsSection {
                platformToolbar

                Text(l10n.text(.accountsSwitchRealHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.managedAccounts.isEmpty {
                    Text(l10n.text(.accountsEmpty))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(orderedAccounts) { account in
                            accountRow(account)
                                .id("\(account.id)-\(account.resolvedDisplayName)-\(account.requiresReauth)")
                        }
                    }
                }

                // The switch and the manual start sit together: one arms the probe,
                // the other fires it once. Both act on the active account.
                HStack(spacing: 12) {
                    Toggle(isOn: autoStartBinding) {
                        Text(l10n.text(.quotaWindowAutoStart))
                    }
                    .toggleStyle(.switch)

                    Spacer(minLength: 8)

                    Button {
                        startWindowForActiveAccount()
                    } label: {
                        Text(l10n.text(.quotaWindowStartNow))
                    }
                    .disabled(model.activeAccountId == nil || model.isStartingQuotaWindow)
                }

                if model.isStartingQuotaWindow {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(l10n.text(.quotaWindowStarting))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = model.quotaWindowStartMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.pendingOAuthURL != nil {
                    oauthAuthorizationLink
                }

                if let message = model.accountOperationMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            AccountTransferExportSheet(
                l10n: l10n,
                rows: exportRows,
                selectedIDs: $exportSelectedIDs,
                isWorking: isExporting,
                onCancel: {
                    showExportSheet = false
                    isExporting = false
                },
                onExport: { performExport() })
        }
        .sheet(isPresented: $showImportPreviewSheet) {
            AccountTransferImportSheet(
                l10n: l10n,
                items: importPreviewItems,
                failures: importPreviewFailures,
                selectedIDs: $importSelectedIDs,
                isWorking: isImportingTransfer,
                onCancel: {
                    clearImportPreview()
                    showImportPreviewSheet = false
                },
                onImport: { performImportSelection() })
        }
        .sheet(isPresented: $showPasteSheet) {
            importSheet(
                title: l10n.text(.accountsAddPaste),
                hint: l10n.text(.accountsPasteHint),
                text: $pasteText,
                sheetError: pasteSheetError,
                isWorking: isImportingPaste)
            {
                isImportingPaste = true
                pasteSheetError = nil
                Task {
                    let ok = await model.importPastedCredentials(pasteText)
                    isImportingPaste = false
                    if ok {
                        pasteText = ""
                        pasteSheetError = nil
                        showPasteSheet = false
                    } else {
                        pasteSheetError = model.lastError ?? l10n.text(.accountsImportNoCredentials)
                    }
                }
            }
        }
        .sheet(isPresented: $showAPIKeySheet) {
            apiKeySheet
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

    /// Starts a window for whichever account is currently active.
    private func startWindowForActiveAccount() {
        guard let id = model.activeAccountId else { return }
        Task {
            // A manual start ignores the auto-start switch: the user asked for this
            // one explicitly, and the probe's other guards still apply.
            await model.startQuotaWindow(accountID: id, autoStartEnabled: true)
        }
    }

    /// Opt-in: enabling this spends a small amount of quota while the user is away.
    private var autoStartBinding: Binding<Bool> {
        Binding(
            get: { model.settings.preferences.autoStartsQuotaWindow },
            set: { model.settings.updateAutoStartsQuotaWindow($0) })
    }

    private var oauthAuthorizationLink: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = model.pendingOAuthURL {
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(l10n.text(.accountsOAuthCopyLink)) {
                    model.copyPendingOAuthURL()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(l10n.text(.accountsOAuthOpenLink)) {
                    model.openPendingOAuthURL()
                }
                .controlSize(.small)
                Button(l10n.text(.cancel)) {
                    model.cancelOAuthLogin()
                }
                .controlSize(.small)
            }
        }
    }

    private var platformToolbar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 8)

            Button {
                openExportSheet()
            } label: {
                Label(l10n.text(.accountsExport), systemImage: "square.and.arrow.up")
            }
            .disabled(currentPlatformAccountCount == 0
                || isExporting
                || isImportingTransfer)

            Menu {
                Button(l10n.text(.accountsAddLocal)) { model.importOfficialAccount() }
                Button(l10n.text(.accountsAddPaste)) { showPasteSheet = true }
                Button(l10n.text(.accountsAddFile)) { pickFiles() }
                Button(l10n.text(.accountsAddOAuth)) { model.startOAuthLogin() }
                    .disabled(model.isOAuthLoginInProgress)
                Button(l10n.text(.accountsAddAPIKey)) { showAPIKeySheet = true }
            } label: {
                Label(l10n.text(.accountsAdd), systemImage: "plus")
            }

            Button {
                model.refreshAllAccountQuotas()
            } label: {
                Label(l10n.text(.accountsRefreshAll), systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshingAccountQuotas)
        }
    }

    private var currentPlatformAccountCount: Int {
        model.managedAccounts.count
    }

    private var exportRows: [AccountTransferExportRow] {
        orderedAccounts.map { account in
            AccountTransferExportRow(
                id: account.id,
                title: account.resolvedDisplayName,
                subtitle: account.email != account.resolvedDisplayName ? account.email : nil)
        }
    }

    private func openExportSheet() {
        let rows = exportRows
        exportSelectedIDs = Set(rows.map(\.id))
        isExporting = false
        showExportSheet = true
    }

    private func performExport() {
        let ids = Array(exportSelectedIDs)
        guard !ids.isEmpty else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "codex-runway-accounts.json"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isExporting = true
            Task { @MainActor in
                _ = model.exportAccounts(ids: ids, to: url)
                isExporting = false
                // Always dismiss so success/error captions in the pane are visible.
                showExportSheet = false
            }
        }
    }

    private var orderedAccounts: [ManagedAccount] {
        model.sidebarAccounts
    }

    private func accountRow(_ account: ManagedAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(account.resolvedDisplayName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if account.id == model.activeAccountId {
                            CurrentAccountTag(l10n: l10n)
                        }
                        SubscriptionTierTag(tier: account.subscriptionTier, l10n: l10n)
                    }
                    if let email = account.email, email != account.resolvedDisplayName {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                    AccountIdentityDetailsLabel(account: account, l10n: l10n)
                    if account.requiresReauth {
                        Text(l10n.text(.accountsNeedsReauth))
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let error = account.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    } else if let quota = account.cachedQuota {
                        Text("\(quota.primaryRemainingPercent)% · \(l10n.text(.lastUpdated)) \(quota.updatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let resetsAt = quota.primaryResetsAt {
                            NextResetCountdownLabel(
                                resetsAt: resetsAt,
                                l10n: l10n,
                                font: .caption)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if account.id != model.activeAccountId {
                        Button(l10n.text(.accountsMakeCurrent)) {
                            restartAfterSwitch = true
                            accountPendingSwitch = account
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    HStack(spacing: 4) {
                        Button {
                            model.moveAccount(id: account.id, direction: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .help(l10n.text(.accountsMoveUp))
                        Button {
                            model.moveAccount(id: account.id, direction: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .help(l10n.text(.accountsMoveDown))
                        Button {
                            restartAfterSwitch = true
                            accountPendingSwitch = account
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .help(l10n.text(.accountsForceCurrent))
                        .disabled(model.isSwitchingAccount)
                        Button {
                            editingAliasId = account.id
                            aliasDraft = account.alias ?? ""
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .help(l10n.text(.alias))
                        Button(role: .destructive) {
                            accountPendingDelete = account
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help(l10n.text(.accountsDelete))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if editingAliasId == account.id {
                HStack {
                    TextField(l10n.text(.alias), text: $aliasDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(l10n.text(.ok)) {
                        model.updateAccountAlias(id: account.id, alias: aliasDraft)
                        editingAliasId = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(l10n.text(.cancel)) {
                        editingAliasId = nil
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(RunwaySurface.fill, in: RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius))
    }

    /// Adds a key-based account.
    ///
    /// The address and API key must identify the same service. The dashboard
    /// token remains optional.
    private var apiKeySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text(.accountsAddAPIKey)).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.text(.newAPIBaseURL))
                    .font(.caption.weight(.medium))
                TextField(l10n.text(.newAPIBaseURLPlaceholder), text: $apiKeyBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Text(l10n.text(.newAPIBaseURLHint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.text(.accountsAPIKeyHint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PasteableTextEditor(text: $apiKeyText, monospaced: true)
                    .frame(minHeight: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.text(.newAPIDashboardToken))
                    .font(.caption.weight(.medium))
                PasteableTextEditor(text: $apiKeyDashboardToken, monospaced: true)
                    .frame(minHeight: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
                Text(l10n.text(.newAPIDashboardTokenHint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = pasteSheetError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(l10n.text(.cancel)) {
                    apiKeyText = ""
                    apiKeyBaseURL = ""
                    apiKeyDashboardToken = ""
                    showAPIKeySheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button(l10n.text(.accountsAdd)) {
                    model.importAPIKey(
                        apiKeyText,
                        relayBaseURL: apiKeyBaseURL,
                        dashboardToken: apiKeyDashboardToken)
                    apiKeyText = ""
                    apiKeyBaseURL = ""
                    apiKeyDashboardToken = ""
                    showAPIKeySheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || apiKeyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func importSheet(
        title: String,
        hint: String,
        text: Binding<String>,
        monospaced: Bool = false,
        sheetError: String? = nil,
        isWorking: Bool = false,
        onSubmit: @escaping () -> Void) -> some View
    {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // PasteableTextView supports ⌘V in LSUIElement apps (SwiftUI TextEditor often does not).
            PasteableTextEditor(text: text, monospaced: monospaced)
                .frame(minHeight: monospaced ? 120 : 160)
                .disabled(isWorking)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
            HStack {
                Button(l10n.text(.accountsPasteFromClipboard)) {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        text.wrappedValue = clip
                    }
                }
                .disabled(isWorking)
                Spacer()
            }
            if let sheetError {
                Text(sheetError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(l10n.text(.cancel)) {
                    showPasteSheet = false
                    showAPIKeySheet = false
                    pasteSheetError = nil
                    isImportingPaste = false
                }
                .disabled(isWorking)
                Button(action: onSubmit) {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(l10n.text(.accountsAdd))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(width: 480)
        .frame(minHeight: sheetError == nil ? 360 : 400)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json, .text, .plainText]
        panel.begin { response in
            guard response == .OK else { return }
            prepareImportPreview(urls: panel.urls)
        }
    }

    private func prepareImportPreview(urls: [URL]) {
        Task { @MainActor in
            isImportingTransfer = true
            defer { isImportingTransfer = false }
            presentImportPreview(model.previewAccountImport(urls: urls))
        }
    }

    private func presentImportPreview(_ preview: CodexAccountImportPreview) {
        codexImportCandidates = preview.items
        importPreviewItems = preview.items.map(\.preview)
        importPreviewFailures = sanitizedFailures(preview.failures)
        importSelectedIDs = Set(preview.items.map(\.id))
        showImportPreviewSheet = !preview.items.isEmpty || !preview.failures.isEmpty
        if preview.items.isEmpty, !preview.failures.isEmpty {
            model.lastError = "\(l10n.text(.accountsImportFailed)): \(importPreviewFailures.prefix(3).joined(separator: "; "))"
        }
    }

    private func performImportSelection() {
        let selected = importSelectedIDs
        guard !selected.isEmpty else { return }
        isImportingTransfer = true
        Task { @MainActor in
            let ok = await model.commitAccountImport(
                candidates: codexImportCandidates,
                selectedIDs: selected)
            isImportingTransfer = false
            if ok {
                clearImportPreview()
                showImportPreviewSheet = false
            }
        }
    }

    private func clearImportPreview() {
        codexImportCandidates = []
        importPreviewItems = []
        importPreviewFailures = []
        importSelectedIDs = []
        isImportingTransfer = false
    }

    private func sanitizedFailures(_ failures: [String]) -> [String] {
        failures.map { failure in
            if failure == "no_credentials" {
                return l10n.text(.accountsImportNoCredentials)
            }
            if failure == "nothing_selected" {
                return l10n.text(.accountsExportEmpty)
            }
            return failure
        }
    }
}
