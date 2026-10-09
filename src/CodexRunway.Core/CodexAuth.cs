using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexRunway.Core;

/// <summary>OAuth token set inside an <c>auth.json</c>.</summary>
public sealed record CodexTokens
{
    public string? IdToken { get; init; }

    public string AccessToken { get; init; } = string.Empty;

    public string RefreshToken { get; init; } = string.Empty;

    public string? AccountId { get; init; }

    public static readonly CodexTokens Empty = new();

    public bool HasOAuthTokens => AccessToken.Length > 0 || RefreshToken.Length > 0;
}

/// <summary>Whether a credential is safe to install as Codex's <c>auth.json</c>.</summary>
public enum LoginUsability
{
    Usable,

    /// <summary>Access token is expired (or missing) and there is no refresh token to renew it.</summary>
    ExpiredAccessWithoutRefresh,

    InvalidTokens,
}

/// <summary>
/// One Codex credential, matching the on-disk <c>auth.json</c> shape exactly.
/// </summary>
/// <remarks>
/// <para>
/// Ported from the macOS app's <c>CodexAuth</c>. The JSON shape is load-bearing: Codex
/// reads this file directly, so the field names, which fields are omitted, and — most
/// importantly — which fields are <i>not</i> written all matter.
/// </para>
/// <para>
/// The rule that is easiest to get wrong: an API-key credential writes only
/// <c>auth_mode</c> and <c>OPENAI_API_KEY</c>, and deliberately omits <c>tokens</c>. A
/// reader that merges into an existing object therefore leaves any previous OAuth tokens
/// in place, producing a file that is simultaneously a key and somebody's ChatGPT login.
/// </para>
/// </remarks>
public sealed record CodexAuth
{
    public const string ApiKeyMode = "apikey";

    public const string ChatGptMode = "chatgpt";

    public string? AuthMode { get; init; }

    public CodexTokens Tokens { get; init; } = CodexTokens.Empty;

    public string? LastRefresh { get; init; }

    /// <summary>Runway-only metadata. Never written into Codex's own auth file.</summary>
    public string? PlanType { get; init; }

    /// <summary>Runway-only metadata. Never written into Codex's own auth file.</summary>
    public string? AuthFilePlanType { get; init; }

    public string? OpenAiApiKey { get; init; }

    /// <summary>API-key-only credential used for managed accounts and switch writes.</summary>
    public static CodexAuth ApiKey(string apiKey) => new()
    {
        AuthMode = ApiKeyMode,
        Tokens = CodexTokens.Empty,
        PlanType = "api",
        AuthFilePlanType = "api",
        OpenAiApiKey = apiKey,
    };

    /// <summary>
    /// True when this credential carries an API key rather than a ChatGPT session.
    /// </summary>
    /// <remarks>
    /// The explicit mode wins over the presence of a key: a file can legitimately hold
    /// both a key and leftover OAuth tokens, and the mode is what says which one Codex
    /// should use.
    /// </remarks>
    public bool IsApiKeyAuth
    {
        get
        {
            var mode = (AuthMode ?? string.Empty).ToLowerInvariant();
            if (mode is ApiKeyMode or "api_key" or "api-key")
            {
                return true;
            }

            if (mode == ChatGptMode)
            {
                return false;
            }

            return !string.IsNullOrEmpty(OpenAiApiKey) && !Tokens.HasOAuthTokens;
        }
    }

    public bool CanRefreshOAuth => Tokens.RefreshToken.Length > 0;

    /// <summary>Whether this credential is usable, and if not, why.</summary>
    public LoginUsability GetLoginUsability()
    {
        if (IsApiKeyAuth)
        {
            return OpenAiApiKey is { Length: >= 8 } ? LoginUsability.Usable : LoginUsability.InvalidTokens;
        }

        // Reject placeholders / truncated junk written by failed switches.
        if (Tokens.AccessToken.Length < 40)
        {
            return LoginUsability.InvalidTokens;
        }

        if (CanRefreshOAuth)
        {
            // Real refresh tokens are long; short strings are corrupt.
            return Tokens.RefreshToken.Length < 20 ? LoginUsability.InvalidTokens : LoginUsability.Usable;
        }

        // Session-style: access only. Allow a switch while the JWT is still valid.
        return TokenInspector.IsExpired(Tokens.AccessToken)
            ? LoginUsability.ExpiredAccessWithoutRefresh
            : LoginUsability.Usable;
    }

    /// <summary>True for a browser-session style credential (access JWT, no refresh token).</summary>
    public bool IsAccessTokenOnly
        => !IsApiKeyAuth && Tokens.AccessToken.Length >= 40 && Tokens.RefreshToken.Length == 0;

    // ------------------------------------------------------------------ JSON

    /// <summary>
    /// Parses an <c>auth.json</c> payload.
    /// </summary>
    /// <exception cref="CodexAuthFormatException">
    /// The payload carries neither tokens nor an API key, so it cannot be a credential.
    /// </exception>
    public static CodexAuth Parse(string json)
    {
        JsonNode node;
        try
        {
            node = JsonNode.Parse(json) ?? throw new CodexAuthFormatException("empty payload");
        }
        catch (JsonException error)
        {
            throw new CodexAuthFormatException($"not valid JSON: {error.Message}");
        }

        if (node is not JsonObject root)
        {
            throw new CodexAuthFormatException("auth.json must be a JSON object");
        }

        var tokens = CodexTokens.Empty;
        if (root["tokens"] is JsonObject tokenObject)
        {
            tokens = new CodexTokens
            {
                IdToken = Str(tokenObject, "id_token"),
                AccessToken = Str(tokenObject, "access_token") ?? string.Empty,
                RefreshToken = Str(tokenObject, "refresh_token") ?? string.Empty,
                AccountId = Str(tokenObject, "account_id"),
            };
        }

        var auth = new CodexAuth
        {
            AuthMode = Str(root, "auth_mode"),
            Tokens = tokens,
            LastRefresh = Str(root, "last_refresh"),
            PlanType = Str(root, "plan_type"),
            AuthFilePlanType = Str(root, "auth_file_plan_type"),
            OpenAiApiKey = Str(root, "OPENAI_API_KEY"),
        };

        if (auth.Tokens.AccessToken.Length == 0
            && auth.Tokens.RefreshToken.Length == 0
            && auth.OpenAiApiKey is null)
        {
            throw new CodexAuthFormatException("auth.json missing tokens and OPENAI_API_KEY");
        }

        return auth;
    }

    /// <summary>
    /// The object to install as Codex's own <c>auth.json</c>: no Runway-only keys.
    /// </summary>
    /// <remarks>
    /// Mirrors the macOS encoder exactly. An API-key credential deliberately omits
    /// <c>tokens</c> rather than writing an empty one, so a key never overwrites a
    /// ChatGPT session with blank tokens — the caller decides whether merging is wanted.
    /// </remarks>
    public JsonObject ToOfficialJsonObject()
    {
        if (Tokens.HasOAuthTokens
            && !string.IsNullOrEmpty(OpenAiApiKey)
            && (AuthMode ?? string.Empty).ToLowerInvariant() is not (ChatGptMode or ApiKeyMode or "api_key" or "api-key"))
        {
            throw new CodexAuthFormatException(
                "Mixed authentication requires an explicit auth_mode");
        }

        var root = new JsonObject
        {
            ["auth_mode"] = IsApiKeyAuth ? ApiKeyMode : ChatGptMode,
        };

        if (IsApiKeyAuth)
        {
            if (OpenAiApiKey is not null)
            {
                root["OPENAI_API_KEY"] = OpenAiApiKey;
            }
        }
        else
        {
            var tokens = new JsonObject
            {
                // Codex expects refresh_token to exist, even when empty.
                ["access_token"] = Tokens.AccessToken,
                ["refresh_token"] = Tokens.RefreshToken,
            };
            if (!string.IsNullOrEmpty(Tokens.IdToken))
            {
                tokens["id_token"] = Tokens.IdToken;
            }

            if (!string.IsNullOrEmpty(Tokens.AccountId))
            {
                tokens["account_id"] = Tokens.AccountId;
            }

            root["tokens"] = tokens;
            if (LastRefresh is not null)
            {
                root["last_refresh"] = LastRefresh;
            }
        }

        return root;
    }

    public string ToOfficialJson() => Serialize(ToOfficialJsonObject());

    /// <summary>
    /// Replaces the credential fields in an existing auth file object, preserving any
    /// other keys that file carried.
    /// </summary>
    /// <remarks>
    /// Codex builds keep their own extra keys in this file, and dropping them would be a
    /// silent downgrade. The macOS implementation merges for the same reason — but note
    /// that merging is also what leaves stale <c>tokens</c> behind when the incoming
    /// credential is an API key, so a caller that wants a clean file must start from an
    /// empty object instead.
    /// </remarks>
    public JsonObject MergedInto(JsonObject existing)
    {
        var merged = (JsonObject)existing.DeepClone();
        foreach (var pair in ToOfficialJsonObject())
        {
            merged[pair.Key] = pair.Value?.DeepClone();
        }

        // Strip Runway-only metadata that can confuse Codex's own file watchers.
        merged.Remove("plan_type");
        merged.Remove("auth_file_plan_type");

        // Codex expects refresh_token to exist even for session-style access tokens.
        if (merged["tokens"] is JsonObject tokens)
        {
            if (tokens["refresh_token"] is null)
            {
                tokens["refresh_token"] = string.Empty;
            }

            if (tokens["id_token"] is { } id && id.GetValue<string>().Length == 0)
            {
                tokens.Remove("id_token");
            }

            if (tokens["account_id"] is { } account && account.GetValue<string>().Length == 0)
            {
                tokens.Remove("account_id");
            }
        }

        return merged;
    }

    /// <summary>A copy with freshly refreshed tokens applied.</summary>
    public CodexAuth WithRefreshResponse(
        string? idToken,
        string accessToken,
        string? refreshToken,
        DateTimeOffset now)
    {
        var updated = Tokens with
        {
            AccessToken = accessToken,
            RefreshToken = string.IsNullOrEmpty(refreshToken) ? Tokens.RefreshToken : refreshToken,
        };
        if (!string.IsNullOrEmpty(idToken))
        {
            updated = updated with { IdToken = idToken };
        }

        return this with { Tokens = updated, LastRefresh = RunwayDates.Format(now) };
    }

    /// <summary>Never prints a secret; used by logs and diagnostic output.</summary>
    public override string ToString()
        => $"CodexAuth(authMode: {AuthMode ?? "unknown"}, accountId: {Tokens.AccountId ?? "none"}, "
           + $"idToken: <redacted>, accessToken: <redacted>, refreshToken: <redacted>, "
           + $"OPENAI_API_KEY: {(OpenAiApiKey is null ? "none" : "<redacted>")})";

    internal static string Serialize(JsonObject root)
        => root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });

    private static string? Str(JsonObject node, string key)
        => node[key] is { } value && value.GetValueKind() == JsonValueKind.String
            ? value.GetValue<string>()
            : null;
}

/// <summary>The payload is not a usable credential.</summary>
public sealed class CodexAuthFormatException : Exception
{
    public CodexAuthFormatException(string message)
        : base(message)
    {
    }
}

/// <summary>Reads the expiry out of a JWT without verifying its signature.</summary>
public static class TokenInspector
{
    /// <summary>
    /// True when the token is expired, unreadable, or within
    /// <paramref name="skewSeconds"/> of expiring.
    /// </summary>
    /// <remarks>
    /// An unparseable token reports as expired: the caller's next step is to refresh,
    /// which is the safe direction to fail in.
    /// </remarks>
    public static bool IsExpired(string? jwt, DateTimeOffset? now = null, double skewSeconds = 60)
    {
        var claims = JwtClaims.Decode(jwt);
        if (claims?["exp"] is not { } exp)
        {
            return true;
        }

        if (!TryAsNumber(exp, out var seconds))
        {
            return true;
        }

        var expiry = DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000));
        var reference = now ?? DateTimeOffset.UtcNow;
        return (expiry - reference).TotalSeconds <= skewSeconds;
    }

    private static bool TryAsNumber(JsonNode value, out double result)
    {
        result = 0;
        switch (value.GetValueKind())
        {
            case JsonValueKind.Number:
                result = value.GetValue<double>();
                return true;
            case JsonValueKind.String:
                return double.TryParse(
                    value.GetValue<string>(),
                    System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture,
                    out result);
            default:
                return false;
        }
    }
}

/// <summary>Decodes a JWT's payload segment. No signature verification — this only reads claims.</summary>
internal static class JwtClaims
{
    public static JsonObject? Decode(string? jwt)
    {
        if (string.IsNullOrEmpty(jwt))
        {
            return null;
        }

        var parts = jwt.Split('.');
        if (parts.Length < 2)
        {
            return null;
        }

        byte[] bytes;
        try
        {
            bytes = Base64Url.Decode(parts[1]);
        }
        catch (FormatException)
        {
            return null;
        }

        try
        {
            return JsonNode.Parse(Encoding.UTF8.GetString(bytes)) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>
/// Base64url with or without padding.
/// </summary>
/// <remarks>
/// JWT segments omit padding, and .NET's <see cref="Convert.FromBase64String"/> rejects
/// that, so padding is restored before decoding.
/// </remarks>
internal static class Base64Url
{
    public static byte[] Decode(string input)
    {
        var text = input.Replace('-', '+').Replace('_', '/');
        var remainder = text.Length % 4;
        if (remainder == 2)
        {
            text += "==";
        }
        else if (remainder == 3)
        {
            text += "=";
        }
        else if (remainder != 0)
        {
            throw new FormatException("invalid base64url length");
        }

        return Convert.FromBase64String(text);
    }
}

/// <summary>ISO-8601 helpers matching the timestamps Codex and ChatGPT write.</summary>
public static class RunwayDates
{
    /// <summary>
    /// Formats a timestamp the way the account index does, with milliseconds.
    /// </summary>
    /// <remarks>
    /// <b>Interoperability.</b> The macOS build encodes every index date with
    /// <c>ISO8601DateFormatter</c> using <c>.withFractionalSeconds</c>, producing
    /// <c>2026-09-28T13:15:30.674Z</c>. The two builds share one <c>index.json</c>, so
    /// this must match that shape exactly: a seconds-precision value would still parse,
    /// but the file would stop looking like itself after a round trip on Windows and any
    /// tool comparing the raw text would see spurious differences.
    /// </remarks>
    public static string FormatIndexDate(DateTimeOffset date)
        => date.ToUniversalTime().ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
            System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>
    /// Parses an index date.
    /// </summary>
    /// <remarks>
    /// Accepts both the fractional form this build writes and the plain form, so a file
    /// produced by an older build or hand-edited by a user still loads.
    /// </remarks>
    public static DateTimeOffset? ParseIndexDate(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return null;
        }

        string[] formats =
        {
            "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'",
        };

        if (DateTimeOffset.TryParseExact(
                text,
                formats,
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AssumeUniversal
                    | System.Globalization.DateTimeStyles.AdjustToUniversal,
                out var exact))
        {
            return exact;
        }

        // Anything else ISO-8601-shaped, including a numeric offset.
        return DateTimeOffset.TryParse(
            text,
            System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AdjustToUniversal
                | System.Globalization.DateTimeStyles.AssumeUniversal,
            out var loose)
            ? loose
            : null;
    }

    /// <summary>
    /// A filesystem-safe UTC stamp, for backup file names.
    /// </summary>
    /// <remarks>
    /// Colons are illegal in Windows file names, so they are dropped rather than
    /// escaped — the same convention the macOS build uses for its backups.
    /// </remarks>
    public static string FileStamp(DateTimeOffset date)
        => date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH-mm-ss'Z'", System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>
    /// Parses an ISO-8601 timestamp, with or without fractional seconds.
    /// </summary>
    /// <remarks>
    /// Both forms occur in practice, so a single format would silently reject half the
    /// inputs rather than fail loudly.
    /// </remarks>
    public static DateTimeOffset? Parse(string? text) => ParseIndexDate(text);

    /// <summary>Formats as internet date-time, seconds precision, UTC.</summary>
    public static string Format(DateTimeOffset date)
        => date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);
}
