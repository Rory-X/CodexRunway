import CodexRunwayCore
import SwiftUI

/// Read-only view of the settings stored for a relay account, and of what the live
/// Codex config currently says.
///
/// Both sides are shown on purpose: this view exists because the file is shared with
/// other tools, so the interesting question is not just "what did we store" but "does
/// the file agree with it right now". A difference is the signal that something else
/// rewrote the config.
struct RelayConfigDetailView: View {
    var account: ManagedAccount
    var stored: RelayConfigProfile?
    var live: RelayConfigProfile?
    var dashboardToken: String?
    var relayKey: String?
    var l10n: L10n
    /// Whether the relay is configured to accept WebSocket transport. The initial
    /// position only; `webSockets` below tracks the user's own clicks.
    var supportsWebSockets: Bool
    /// Flips WebSocket transport for this account's provider.
    var onToggleWebSockets: (Bool) -> Void
    var onClose: () -> Void

    /// Mirrors `supportsWebSockets` after the first render.
    ///
    /// The sheet is constructed once, so reading the input directly would leave the
    /// switch showing its original position after a click.
    @State private var webSockets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let stored, !stored.isEmpty {
                        storedSection(stored)
                    } else {
                        Text(l10n.text(.relayConfigNotStored))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    liveSection
                    webSocketSection
                    credentialsSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 520)
        .onAppear { webSockets = supportsWebSockets }
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.text(.relayConfigDetailTitle))
                .font(.headline)
            Text(account.resolvedDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if let stored {
                Text(verbatim: String(
                    format: l10n.text(.relayConfigCapturedAt),
                    ResetCreditDateFormatter.updatedAt(stored.capturedAt, language: l10n.language)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(l10n.text(.ok), action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Sections

    private func storedSection(_ stored: RelayConfigProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(l10n.text(.relayConfigStoredSection))
            // Compared against the live file so a value another tool overwrote is
            // visibly different rather than silently wrong.
            ForEach(stored.displayFields) { field in
                fieldRow(
                    field.key,
                    value: field.value,
                    differs: liveValue(field.key) != nil && liveValue(field.key) != field.value)
            }
        }
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(l10n.text(.relayConfigLiveSection))
            if let live, !live.isEmpty {
                ForEach(live.displayFields) { field in
                    fieldRow(field.key, value: field.value, differs: false)
                }
            } else {
                Text(l10n.text(.relayConfigLiveUnavailable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// WebSocket transport is a compatibility switch, not a preference.
    ///
    /// Codex will use a WebSocket for the response stream when the provider claims to
    /// support it. Relays commonly advertise support without actually implementing it,
    /// and the failure is opaque: the stream is closed by the server before the
    /// response completes. Turning it off makes Codex use plain HTTP streaming, which
    /// every relay handles.
    private var webSocketSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(l10n.text(.relayWebSocketSection))
            Toggle(isOn: Binding(
                get: { webSockets },
                set: { newValue in
                    webSockets = newValue
                    onToggleWebSockets(newValue)
                })
            ) {
                Text(l10n.text(.relayWebSocketToggle))
            }
            .toggleStyle(.switch)
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(l10n.text(.relayConfigCredentialsSection))
            fieldRow(
                l10n.text(.relayConfigRelayKey),
                value: SecretMasking.mask(relayKey) ?? l10n.text(.relayConfigNotSet),
                differs: false)
            fieldRow(
                l10n.text(.newAPIDashboardToken),
                value: SecretMasking.mask(dashboardToken) ?? l10n.text(.relayConfigNotSet),
                differs: false)
        }
    }

    // MARK: - Row

    private func fieldRow(_ key: String, value: String?, differs: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: key)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 168, alignment: .leading)
            Text(verbatim: SecretMasking.sanitizedURL(value) ?? "—")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(differs ? Color(nsColor: .systemOrange) : .primary)
            if differs {
                // Says why the value is highlighted rather than leaving the colour to
                // be interpreted.
                Text(l10n.text(.relayConfigDiffers))
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
            Spacer(minLength: 0)
        }
    }

    /// The live file's value for a stored field's key.
    private func liveValue(_ key: String) -> String? {
        guard let live else { return nil }
        for field in live.displayFields where field.key == key { return field.value }
        return nil
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
    }
}
