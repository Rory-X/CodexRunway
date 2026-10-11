import Foundation
import Security

/// Stores the New API dashboard PAT (Personal Access Token) for a managed account.
///
/// The PAT is a *dashboard* credential, distinct from the account's `sk-` relay key:
///
/// - `sk-` key  → `/v1/*` (OpenAI-compatible relay + two billing endpoints)
/// - PAT        → `/api/*` (full dashboard API: balance, usage, request log)
///
/// The PAT is optional. Without it the app can still read the key's own spend.
/// It is never written to `index.json` or any export — only the Keychain, keyed by
/// the managed account id, mirroring `ProxyCredentialStore`.
public struct NewAPITokenStore: Sendable {
    public static let defaultService = "com.github.codex-runway.newapi"

    private let read: @Sendable (String, Bool) throws -> String
    private let write: @Sendable (String, String) throws -> Void
    private let remove: @Sendable (String) throws -> Void

    public init(service: String = NewAPITokenStore.defaultService) {
        read = { id, interactive in
            var query = Self.query(service: service, id: id)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = try Self.copyMatching(query, allowInteraction: interactive)
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty
            else { throw NewAPITokenStoreError.unavailable }
            return token
        }
        write = { token, id in
            guard !token.isEmpty else { throw NewAPITokenStoreError.invalidToken }
            let data = Data(token.utf8)
            let query = Self.query(service: service, id: id)
            let values = [kSecValueData as String: data] as CFDictionary
            var status = SecItemUpdate(query as CFDictionary, values)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw NewAPITokenStoreError.writeFailed }
        }
        remove = { id in
            let status = SecItemDelete(Self.query(service: service, id: id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NewAPITokenStoreError.writeFailed
            }
        }
    }

    /// Test seam.
    init(
        read: @escaping @Sendable (String, Bool) throws -> String,
        write: @escaping @Sendable (String, String) throws -> Void,
        remove: @escaping @Sendable (String) throws -> Void)
    {
        self.read = read
        self.write = write
        self.remove = remove
    }

    /// Reads the PAT, returning nil when none is stored (the optional case).
    public func token(for accountID: String) -> String? {
        do {
            return try read(accountID, false)
        } catch {
            return nil
        }
    }

    /// The read failure behind `token(for:)` returning nil, if there was one.
    ///
    /// `token(for:)` answers "is a PAT usable right now", which is what callers
    /// want, but a Keychain that refuses access and an account with no PAT stored
    /// both collapse to nil there. That made a readable token look *deleted* — the
    /// panel said "add a dashboard token" while the token was still in the
    /// Keychain. This distinguishes the two so the UI can say which it is.
    public enum ReadOutcome: Sendable, Equatable {
        case token
        case notStored
        /// Present but unreadable this time: locked keychain, or the running build
        /// is not on the item's access list yet.
        case unreadable
    }

    public func readOutcome(for accountID: String) -> ReadOutcome {
        do {
            _ = try read(accountID, false)
            return .token
        } catch NewAPITokenStoreError.interactionNotAllowed {
            return .unreadable
        } catch NewAPITokenStoreError.unavailable {
            return .notStored
        } catch {
            return .unreadable
        }
    }

    public func hasToken(for accountID: String) -> Bool {
        token(for: accountID) != nil
    }

    public func save(_ token: String, for accountID: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NewAPITokenStoreError.invalidToken }
        try write(trimmed, accountID)
    }

    public func delete(for accountID: String) throws {
        try remove(accountID)
    }

    private static func query(service: String, id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }

    private static func copyMatching(
        _ query: [String: Any],
        allowInteraction: Bool) throws -> (OSStatus, Any?)
    {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // A locked keychain is not the same as "no token stored": treating it as
        // absent would silently downgrade the account to key-only mode. Surface it
        // so the caller can distinguish "no PAT" from "could not read PAT".
        if status == errSecInteractionNotAllowed, !allowInteraction {
            throw NewAPITokenStoreError.interactionNotAllowed
        }
        return (status, result)
    }
}

public enum NewAPITokenStoreError: Error, Equatable, Sendable {
    case unavailable
    case invalidToken
    case writeFailed
    case interactionNotAllowed
}
