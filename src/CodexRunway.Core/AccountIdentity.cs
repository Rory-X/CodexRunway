using System.Security.Cryptography;
using System.Text;

namespace CodexRunway.Core;

/// <summary>
/// Derives the stable identifiers used to decide whether two credentials are the same
/// account.
/// </summary>
/// <remarks>
/// <para>
/// <b>This must match the macOS build exactly.</b> An account's directory is named from this
/// value, so a different result on one platform means the same login lands in two different
/// folders and neither build can see the other's credential — the whole point of the shared
/// layout.
/// </para>
/// <para>
/// The hash is deliberately <i>not</i> cryptographic: it is an identifier, not a security
/// boundary, and the value it has to reproduce comes from the macOS implementation. That
/// also means <see cref="object.GetHashCode"/> is unusable — .NET randomises string hashing
/// per process, so identifiers would change on every launch and mint a fresh directory each
/// time. The algorithm is reproduced literally instead.
/// </para>
/// </remarks>
public static class AccountIdentity
{
    /// <summary>
    /// The FNV-style rolling hash the macOS build uses.
    /// </summary>
    /// <remarks>
    /// Seed 5381, multiplier 127 over UTF-8 bytes, wrapping at 64 bits, rendered as
    /// lowercase hexadecimal with no padding. The multiplier is 127 rather than the 33 of
    /// classic djb2, which is the detail that makes a plausible-looking port wrong.
    /// </remarks>
    public static string StableHash(string value)
    {
        var hash = 5_381UL;
        foreach (var b in Encoding.UTF8.GetBytes(value))
        {
            // unchecked: the macOS implementation multiplies with &* , i.e. wraps.
            hash = unchecked((127UL * hash) + b);
        }

        // "x" rather than Convert.ToString(hash, 16): the latter is signed and would render
        // a value above 2^63 as negative.
        return hash.ToString("x", System.Globalization.CultureInfo.InvariantCulture);
    }

    /// <summary>Fingerprint of an API key, trimmed the way the macOS build trims it.</summary>
    public static string ApiKeyFingerprint(string apiKey)
        => StableHash(apiKey.Trim());

    /// <summary>
    /// Fingerprint of an OAuth credential, prefixed by which token it came from.
    /// </summary>
    /// <remarks>
    /// The prefix is part of the identifier, not decoration: the same textual value used as a
    /// refresh token and as an access token must not collide.
    /// </remarks>
    public static string OAuthFingerprint(CodexAuth auth)
    {
        if (auth.Tokens.RefreshToken.Length > 0)
        {
            return "rt-" + StableHash(auth.Tokens.RefreshToken);
        }

        if (auth.Tokens.AccessToken.Length > 0)
        {
            return "at-" + StableHash(auth.Tokens.AccessToken);
        }

        // No token at all: the caller gets a value that cannot collide with a real one.
        return "unknown-" + StableHash(Guid.NewGuid().ToString());
    }

    /// <summary>
    /// The identifier a managed account is keyed by.
    /// </summary>
    /// <remarks>
    /// Prefixed by credential kind so an API key and an OAuth login can never produce the
    /// same id, matching the macOS format of <c>api-&lt;hash&gt;</c> / <c>oauth-&lt;hash&gt;</c>.
    /// Existing directories on disk follow exactly this shape, which is what makes the two
    /// builds agree on where an account lives.
    /// </remarks>
    public static string ManagedAccountId(CodexAuth auth)
        => auth.IsApiKeyAuth
            ? "api-" + StableHash(auth.OpenAiApiKey ?? string.Empty)
            : "oauth-" + StableHash(auth.Tokens.RefreshToken.Length > 0
                ? auth.Tokens.RefreshToken
                : auth.Tokens.AccessToken);

    /// <summary>
    /// Whether a credential belongs to the account a row describes.
    /// </summary>
    /// <remarks>
    /// <para>
    /// An API key matches on the key itself. An OAuth credential matches on the account's own
    /// id when one is known, then on the subject, then on the email, each paired with the
    /// account id — the same order the macOS build uses, because a user or workspace id is
    /// the only field that survives a re-login.
    /// </para>
    /// <para>
    /// When none of those identify the credential, the derived id is compared as a last
    /// resort. That is deliberately permissive: refusing a repair because the claims were
    /// unreadable would be worse than accepting the credential the user just signed in with.
    /// </para>
    /// </remarks>
    public static bool Matches(
        string accountId,
        string? managedUserId,
        string? managedSubjectId,
        string? managedEmail,
        CodexAuth auth)
    {
        if (auth.IsApiKeyAuth)
        {
            return string.Equals(
                accountId,
                "api-" + StableHash(auth.OpenAiApiKey ?? string.Empty),
                StringComparison.Ordinal);
        }

        var claims = JwtClaims.Decode(auth.Tokens.IdToken) ?? JwtClaims.Decode(auth.Tokens.AccessToken);
        var account = OAuthAccountId(auth);

        if (managedUserId is { Length: > 0 } userId && account is { Length: > 0 }
            && string.Equals(userId, ClaimUserId(claims), StringComparison.Ordinal))
        {
            return true;
        }

        if (managedSubjectId is { Length: > 0 } subject && account is { Length: > 0 }
            && string.Equals(subject, ClaimSubject(claims), StringComparison.Ordinal))
        {
            return true;
        }

        if (managedEmail is { Length: > 0 } email && account is { Length: > 0 }
            && string.Equals(email, ClaimEmail(claims), StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return string.Equals(accountId, ManagedAccountId(auth), StringComparison.Ordinal);
    }

    // ---------------------------------------------------------------- claim reading

    /// <summary>
    /// The account or workspace id a credential identifies.
    /// </summary>
    /// <remarks>
    /// The explicit <c>account_id</c> wins, because a user can select a workspace while the
    /// token still carries the original one. Falling back to the organisation id is what
    /// keeps a workspace-scoped login attached to the same account across re-issues.
    /// </remarks>
    internal static string? OAuthAccountId(CodexAuth auth)
    {
        if (auth.Tokens.AccountId is { Length: > 0 } explicitId)
        {
            return explicitId;
        }

        var claims = JwtClaims.Decode(auth.Tokens.IdToken) ?? JwtClaims.Decode(auth.Tokens.AccessToken);
        return claims is null ? null : Nested(claims, "account_id") ?? Nested(claims, "organization_id");
    }

    internal static string? ClaimUserId(System.Text.Json.Nodes.JsonObject? claims)
        => claims is null ? null : Nested(claims, "chatgpt_user_id") ?? Nested(claims, "user_id");

    internal static string? ClaimSubject(System.Text.Json.Nodes.JsonObject? claims)
        => claims is null ? null : Root(claims, "sub");

    internal static string? ClaimEmail(System.Text.Json.Nodes.JsonObject? claims)
    {
        if (claims is null)
        {
            return null;
        }

        return Root(claims, "email")
            ?? (claims["https://api.openai.com/profile"] is System.Text.Json.Nodes.JsonObject profile
                ? Root(profile, "email")
                : null);
    }

    /// <summary>A top-level claim, or null when it is absent or not a non-empty string.</summary>
    private static string? Root(System.Text.Json.Nodes.JsonObject claims, string key)
        => claims[key] is { } node
            && node.GetValueKind() == System.Text.Json.JsonValueKind.String
            && node.GetValue<string>() is { Length: > 0 } text
                ? text
                : null;

    /// <summary>
    /// A claim inside the namespaced <c>https://api.openai.com/auth</c> object.
    /// </summary>
    /// <remarks>
    /// These fields are not at the top level of the token. A reader that looks only there
    /// finds nothing and silently falls back to a weaker identifier.
    /// </remarks>
    private static string? Nested(System.Text.Json.Nodes.JsonObject claims, string key)
        => claims["https://api.openai.com/auth"] is System.Text.Json.Nodes.JsonObject auth
            ? Root(auth, key)
            : null;
}
