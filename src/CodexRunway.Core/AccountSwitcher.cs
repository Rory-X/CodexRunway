namespace CodexRunway.Core;

/// <summary>How a switch ended.</summary>
public enum SwitchOutcomeKind
{
    /// <summary>The account is installed and Codex is pointed at it.</summary>
    Switched,

    /// <summary>Nothing to do: the account was already current.</summary>
    AlreadyCurrent,

    /// <summary>The switch did not happen; <see cref="SwitchOutcome.Reason"/> says why.</summary>
    Failed,
}

/// <summary>The result of a switch attempt.</summary>
public sealed record SwitchOutcome(
    SwitchOutcomeKind Kind,
    string? AccountId = null,
    string? Reason = null,
    bool CredentialInstalled = false,
    bool ConfigUpdated = false)
{
    public bool Succeeded => Kind is SwitchOutcomeKind.Switched or SwitchOutcomeKind.AlreadyCurrent;

    public static SwitchOutcome Failed(string reason, bool credentialInstalled = false)
        => new(SwitchOutcomeKind.Failed, Reason: reason, CredentialInstalled: credentialInstalled);
}

/// <summary>
/// Makes an account the one Codex uses.
/// </summary>
/// <remarks>
/// <para>
/// A switch is two writes that must agree: the credential goes to <c>~/.codex/auth.json</c> and
/// the routing goes to <c>~/.codex/config.toml</c>. Codex reads both, and a half-applied switch
/// is worse than none — a relay credential with an official provider, or an official credential
/// pointed at a relay address, fails in a way that looks like a broken key rather than a broken
/// switch.
/// </para>
/// <para>
/// Order matters for the same reason. The config is written first and the credential second, so
/// the window where the two disagree leaves the <i>old</i> credential in place with routing for
/// the new account: the next request fails on authentication and nothing is billed. The reverse
/// order would send the new account's credential to the old account's endpoint.
/// </para>
/// <para>
/// Codex is deliberately not restarted here. Whether to restart is a product decision that
/// differs by host, and this method's job is to leave the files consistent.
/// </para>
/// </remarks>
public sealed class AccountSwitcher
{
    private readonly RunwayPaths _paths;
    private readonly CredentialStore _store;

    public AccountSwitcher(RunwayPaths paths, CredentialStore store)
    {
        _paths = paths;
        _store = store;
    }

    /// <summary>
    /// Installs an account's credential and points Codex at it.
    /// </summary>
    /// <param name="providerName">
    /// The <c>model_provider</c> to select, or null to clear it so Codex uses its own default —
    /// which is what a subscription account needs.
    /// </param>
    public SwitchOutcome SwitchTo(string accountId, string? providerName)
    {
        CodexAuth auth;
        try
        {
            auth = _store.LoadCredential(accountId);
        }
        catch (CredentialStoreException error)
        {
            return SwitchOutcome.Failed(error.Problem switch
            {
                CredentialProblem.Missing => "account_credential_missing",
                CredentialProblem.Invalid => "account_credential_invalid",
                CredentialProblem.Unreadable => "account_credential_unreadable",
                _ => "account_credential_unusable",
            });
        }

        if (auth.GetLoginUsability() != LoginUsability.Usable)
        {
            // Installing this would sign the user out rather than switch them.
            return SwitchOutcome.Failed("account_credential_unusable");
        }

        // 1. Routing first, so a failure here leaves the old credential paired with the old
        //    endpoint — an inert combination rather than a mismatched one.
        //
        // Called unconditionally: the editor already treats a missing config as "nothing to do"
        // and reports an unusable one as a failure. Guarding on File.Exists here looked like a
        // shortcut and was a bug — that check is false for a path that exists as a directory, so
        // the whole step was skipped and a write that cannot succeed was reported as a switch.
        var configResult = CodexConfigProviderEditor.SetSelectedProvider(
            providerName, _paths.ConfigPath, _paths.BackupDirectory);

        if (configResult.Kind == ConfigEditKind.Failed)
        {
            return SwitchOutcome.Failed(configResult.Reason ?? "config_write_failed");
        }

        var configUpdated = configResult.Kind == ConfigEditKind.Updated;

        // 2. Credential second.
        try
        {
            // A complete replacement, never a merge: merging would carry the previous account's
            // tokens into this one, and any path that reads the token would then act as the
            // wrong account.
            _store.InstallOfficialAuth(auth);
        }
        catch (CredentialStoreException)
        {
            return SwitchOutcome.Failed("credential_install_failed");
        }
        catch (IOException)
        {
            return SwitchOutcome.Failed("credential_install_failed");
        }
        catch (UnauthorizedAccessException)
        {
            return SwitchOutcome.Failed("credential_install_failed");
        }

        return new SwitchOutcome(
            SwitchOutcomeKind.Switched,
            AccountId: accountId,
            CredentialInstalled: true,
            ConfigUpdated: configUpdated);
    }

    /// <summary>
    /// The provider a switch should select for an account.
    /// </summary>
    /// <remarks>
    /// A subscription account must clear the provider so Codex uses its own default endpoint; a
    /// relay account must select the relay's section. Getting this backwards is the failure the
    /// macOS build's comments describe — an official credential talking to a relay address.
    /// </remarks>
    public static string? ProviderFor(CodexAuth auth, string? relayProviderName)
        => auth.IsApiKeyAuth ? (relayProviderName ?? "custom") : null;
}
