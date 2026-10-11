using CodexRunway.Core;

namespace CodexRunway.Presentation;

/// <summary>How an account row should be presented.</summary>
public enum RowTone
{
    /// <summary>Usable, nothing to draw attention to.</summary>
    Normal,

    /// <summary>Usable but notable — an approaching limit, an expiring credential.</summary>
    Caution,

    /// <summary>Not usable until the user acts.</summary>
    Problem,

    /// <summary>Currently the account Codex is using.</summary>
    Active,
}

/// <summary>
/// One account as the window shows it.
/// </summary>
/// <remarks>
/// Built from a <see cref="CodexAuth"/> and the account's stored metadata. It holds no
/// secret: the key is reduced to a masked label at construction, so a row can be logged,
/// serialised in a crash report, or shown in a tooltip without leaking anything. That is a
/// deliberate departure from passing the credential around — the macOS app redacts by
/// discipline, which is easy to forget at a call site.
/// </remarks>
public sealed record AccountRow
{
    public required string Id { get; init; }

    /// <summary>What the user called this account, falling back to a derived name.</summary>
    public required string Title { get; init; }

    /// <summary>Secondary line: plan, workspace, or the masked key.</summary>
    public string? Subtitle { get; init; }

    public required bool IsApiKey { get; init; }

    public required LoginUsability Usability { get; init; }

    public bool IsActive { get; init; }

    /// <summary>True when the credential needs the user to sign in again.</summary>
    public bool NeedsReauth { get; init; }

    /// <summary>Quota as a percentage of the window used, when known.</summary>
    public double? UsedPercent { get; init; }

    /// <summary>A short quota summary, e.g. "62% · resets in 3h".</summary>
    public string? QuotaSummary { get; init; }

    public RowTone Tone => ResolveTone();

    /// <summary>
    /// The account is unusable, so it must read as a problem rather than as a preference.
    /// </summary>
    public bool CanActivate => Usability == LoginUsability.Usable && !NeedsReauth;

    /// <summary>
    /// Builds a row, masking any credential material.
    /// </summary>
    /// <remarks>
    /// The masked key keeps its length and its first four characters, matching the macOS
    /// app's rule and the relay panel's own convention. Keeping the length matters because
    /// a user compares it against the panel that issued the key to spot a truncated paste.
    /// </remarks>
    public static AccountRow From(
        string id,
        string? alias,
        string? displayName,
        string? email,
        CodexAuth auth,
        bool isActive,
        bool needsReauth,
        double? usedPercent = null,
        string? quotaSummary = null,
        string? planType = null)
    {
        const string FallbackTitle = "(unnamed account)";

        var title = FirstNonEmpty(alias, displayName, email) ?? MaskedKey(auth) ?? FallbackTitle;
        // The stored plan is preferred over the credential's, because the index is what the
        // settings window writes and therefore what the user last saw.
        var subtitle = SubtitleFor(alias, displayName, email, auth, planType);

        return new AccountRow
        {
            Id = id,
            Title = title,
            Subtitle = subtitle,
            IsApiKey = auth.IsApiKeyAuth,
            Usability = auth.GetLoginUsability(),
            IsActive = isActive,
            NeedsReauth = needsReauth,
            UsedPercent = usedPercent,
            QuotaSummary = quotaSummary,
        };
    }

    private RowTone ResolveTone()
    {
        if (NeedsReauth || Usability != LoginUsability.Usable)
        {
            return RowTone.Problem;
        }

        if (IsActive)
        {
            return RowTone.Active;
        }

        // An account close to its limit is worth noticing before it runs out.
        return UsedPercent is >= 80 ? RowTone.Caution : RowTone.Normal;
    }

    private static string? SubtitleFor(
        string? alias,
        string? displayName,
        string? email,
        CodexAuth auth,
        string? storedPlan)
    {
        if (auth.IsApiKeyAuth)
        {
            var masked = MaskedKey(auth);
            return masked is null ? null : masked;
        }

        // For a subscription account the plan is the useful second line.
        var plan = storedPlan ?? auth.PlanType ?? auth.AuthFilePlanType;
        var identity = FirstNonEmpty(email, displayName);

        return (plan, identity) switch
        {
            (not null, not null) => $"{plan} · {identity}",
            (not null, null) => plan,
            (null, not null) => identity,
            _ => alias is null ? null : displayName,
        };
    }

    /// <summary>
    /// A key reduced to something safe to display. Never returns more than four characters
    /// of the original.
    /// </summary>
    private static string? MaskedKey(CodexAuth auth)
    {
        var key = auth.OpenAiApiKey;
        if (string.IsNullOrEmpty(key))
        {
            return null;
        }

        // Short values are masked whole: four characters out of five is not a mask.
        if (key.Length <= 8)
        {
            return new string('•', 8);
        }

        return key[..4] + new string('•', Math.Min(8, key.Length - 4));
    }

    private static string? FirstNonEmpty(params string?[] values)
        => values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));
}
