import Foundation

/// Redacts credentials for display.
///
/// A detail view exists to make the *configuration* auditable, which does not require
/// showing the secret itself. Masking keeps enough shape to recognise which credential
/// is stored — its prefix and length — without printing anything reusable from a
/// screenshot or a bug report.
public enum SecretMasking {
    /// A masked rendering of `secret`, or nil when there is nothing to show.
    ///
    /// Short secrets are masked entirely: revealing the first few characters of an
    /// eight-character value would reveal most of it.
    public static func mask(_ secret: String?) -> String? {
        guard let secret, !secret.isEmpty else { return nil }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.count <= 8 {
            return String(repeating: "•", count: 8)
        }
        // Keep a recognisable head, and the length so a truncated paste is obvious.
        let head = trimmed.prefix(4)
        let tail = trimmed.suffix(2)
        return "\(head)••••\(tail)  (\(trimmed.count) chars)"
    }

    /// A URL with any userinfo removed, so a credential embedded in an address is not
    /// echoed back.
    public static func sanitizedURL(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)) else {
            return raw
        }
        if components.user != nil || components.password != nil {
            components.user = nil
            components.password = nil
        }
        // A `?key=…` query is the other common way a credential leaks into a URL.
        if let items = components.queryItems {
            let redacted = items.map { item -> URLQueryItem in
                let sensitive = ["key", "token", "api_key", "apikey", "password", "secret"]
                if sensitive.contains(item.name.lowercased()) {
                    return URLQueryItem(name: item.name, value: "••••")
                }
                return item
            }
            components.queryItems = redacted
        }
        return components.string ?? raw
    }
}
