import Foundation

/// Turns the account error codes stored in `index.json` into text a person can read.
///
/// The codes are persisted state, so they have to stay stable and machine-readable —
/// `relay_refresh_failed` and friends are written by the refresher and compared in
/// tests. Rendering them directly put internal identifiers on screen, which tells the
/// user nothing about what went wrong or what to do about it.
public enum AccountErrorCode {
    /// The codes this app writes into `lastError`.
    public static let known: Set<String> = [
        "credential_missing",
        "invalid_credential",
        "invalid credential",
        "relay_base_url_missing",
        "relay_credential_unavailable",
        "relay_key_rejected",
        "relay_refresh_failed",
    ]

    /// A localized description, or nil when the value is not one of ours.
    ///
    /// Nil for anything unrecognised so callers can fall back to showing the raw text:
    /// some errors are already user-facing (an import failure wraps its own message),
    /// and replacing those with a generic string would lose detail.
    public static func localizedText(for code: String, l10n: L10n) -> String? {
        switch code {
        case "credential_missing":
            return l10n.text(.accountErrorCredentialMissing)
        case "invalid_credential", "invalid credential":
            return l10n.text(.accountErrorInvalidCredential)
        case "relay_base_url_missing":
            return l10n.text(.accountErrorRelayBaseURLMissing)
        case "relay_credential_unavailable":
            return l10n.text(.accountErrorRelayCredentialUnavailable)
        case "relay_key_rejected":
            return l10n.text(.accountErrorRelayKeyRejected)
        case "relay_refresh_failed":
            return l10n.text(.accountErrorRelayRefreshFailed)
        default:
            return nil
        }
    }
}

/// Errors from reading an account's quota.
public enum QuotaError: Error, LocalizedError, Equatable {
    /// The account has no ChatGPT quota to read.
    ///
    /// Returned for a relay key rather than attempting the request: `auth.json` can hold
    /// a leftover `tokens` block beside the key, and a request made with it succeeds
    /// against whatever account that token belongs to. The result would be another
    /// account's quota windows presented as this one's.
    case notApplicable

    /// Localized rather than left to the default bridge.
    ///
    /// A plain `Error` becomes an `NSError` whose description is the framework's own
    /// "The operation couldn't be completed. (… error 0.)" — an unactionable sentence
    /// naming an internal type. This case also describes a *normal* state rather than a
    /// fault: a relay account simply has no ChatGPT window, which is not something to
    /// report as a failure.
    public var errorDescription: String? {
        L10n(preference: .system).text(.accountErrorQuotaNotApplicable)
    }
}

/// Whether a credential can report ChatGPT quota at all.
public enum QuotaEligibility {
    /// False for a relay key.
    ///
    /// A key does not report ChatGPT windows, and the decision has to come from the
    /// credential rather than from the account record: `auth.json` can carry a leftover
    /// `tokens` block beside the key, and a request made with it succeeds against
    /// whichever account that token belongs to — returning another account's windows.
    public static func canReportQuota(_ auth: CodexAuth) -> Bool {
        !auth.isAPIKeyAuth
    }
}
