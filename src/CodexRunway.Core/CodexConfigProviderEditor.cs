using System.Text;
using System.Text.RegularExpressions;

namespace CodexRunway.Core;

/// <summary>What an edit did, so a caller can tell "already correct" from "failed".</summary>
public enum ConfigEditKind
{
    /// <summary>The file already said what it needed to say.</summary>
    Unchanged,

    /// <summary>The file was rewritten.</summary>
    Updated,

    /// <summary>Nothing was written; <see cref="ConfigEditOutcome.Reason"/> says why.</summary>
    Failed,
}

/// <summary>The result of an edit. <see cref="Reason"/> is a stable code, not user text.</summary>
public sealed record ConfigEditOutcome(
    ConfigEditKind Kind,
    string? Previous = null,
    string? Current = null,
    string? Reason = null)
{
    public static readonly ConfigEditOutcome Unchanged = new(ConfigEditKind.Unchanged);

    public static ConfigEditOutcome Updated(string? previous, string? current)
        => new(ConfigEditKind.Updated, previous, current);

    public static ConfigEditOutcome Failed(string reason)
        => new(ConfigEditKind.Failed, Reason: reason);

    public bool Succeeded => Kind != ConfigEditKind.Failed;
}

/// <summary>
/// Rewrites <b>only</b> the parts of Codex's <c>config.toml</c> that say where traffic
/// goes, leaving everything else byte-for-byte intact.
/// </summary>
/// <remarks>
/// <para>
/// Ported from the macOS app's <c>CodexConfigProviderEditor</c>. Why it exists:
/// <c>model_provider</c> is the single global switch for <i>where</i> traffic goes, while
/// <c>auth.json</c> only says <i>which credential</i> to present. A relay account and an
/// official account need different providers, but switching accounts used to leave this
/// line untouched — so an official OAuth credential kept talking to the relay address.
/// Every other line (plugins, mcp_servers, projects, desktop settings, model, catalogs)
/// is preserved, because the file belongs to Codex and is re-serialized by it.
/// </para>
/// <para>
/// All edits are whole-file rewrites through a temporary file, so an interrupted write
/// cannot leave a half-written config behind.
/// </para>
/// </remarks>
public static partial class CodexConfigProviderEditor
{
    /// <summary>
    /// Backups live in CodexRunway's own directory: <c>config.toml</c> is Codex's file,
    /// and it is already littered with other tools' <c>.bak</c> files.
    /// </summary>
    public static string DefaultBackupDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".codex-runway",
        "config-backups");

    /// <summary><c>~/.codex/config.toml</c> — Codex's own config, the source of truth
    /// for which provider is selected.</summary>
    public static string DefaultConfigPath => CodexConfigReader.DefaultConfigPath;

    /// <summary>
    /// Sets the top-level <c>model_provider</c> to <paramref name="name"/>, or removes
    /// the line when it is null (which restores Codex's own default provider — the
    /// official endpoint for a ChatGPT login).
    /// </summary>
    public static ConfigEditOutcome SetSelectedProvider(
        string? name,
        string configPath,
        string? backupDirectory = null)
    {
        var trimmed = name?.Trim();
        var normalized = string.IsNullOrEmpty(trimmed) ? null : trimmed;

        // No config file means Codex is running on its built-in defaults, which is
        // exactly the state we would write for an official account. Creating the file
        // ourselves would be a far larger step than the user asked for.
        if (!File.Exists(configPath))
        {
            return ConfigEditOutcome.Unchanged;
        }

        var text = TryRead(configPath);
        if (text is null)
        {
            return ConfigEditOutcome.Failed("config_unreadable");
        }

        var previous = CodexConfigReader.SelectedProviderFromToml(text);
        if (previous == normalized)
        {
            return ConfigEditOutcome.Unchanged;
        }

        var rewritten = ReplacingTopLevelProvider(text, normalized);
        return WriteOutcome(rewritten, text, configPath, backupDirectory, previous, normalized);
    }

    /// <summary>
    /// Creates a <c>[model_providers.&lt;name&gt;]</c> section when the file has none.
    /// </summary>
    /// <remarks>
    /// Codex re-serializes the config from its own model, and a section it does not
    /// recognise can be dropped entirely rather than merely emptied. Without the section
    /// there is nowhere to put <c>base_url</c>, so a relay account would fall back to the
    /// official endpoint while still presenting its relay key — the request then fails
    /// authentication against a host that never issued the key.
    /// </remarks>
    public static ConfigEditOutcome EnsureProviderSection(
        string name,
        string baseUrl,
        string? wireApi = "responses",
        bool? requiresOpenAiAuth = true,
        string? displayName = null,
        string configPath = "",
        string? backupDirectory = null)
    {
        var provider = name.Trim();
        var address = baseUrl.Trim();
        if (provider.Length == 0 || address.Length == 0)
        {
            return ConfigEditOutcome.Failed("invalid_argument");
        }

        if (!File.Exists(configPath))
        {
            return ConfigEditOutcome.Unchanged;
        }

        var text = TryRead(configPath);
        if (text is null)
        {
            return ConfigEditOutcome.Failed("config_unreadable");
        }

        // An existing section is left to the field setters, which keep its other keys.
        if (SectionRange(provider, text) is not null)
        {
            return ConfigEditOutcome.Unchanged;
        }

        var block = new StringBuilder();
        block.Append('\n').Append("[model_providers.").Append(provider).Append("]\n");
        block.Append("name = ").Append(Quoted(displayName ?? provider)).Append('\n');
        if (requiresOpenAiAuth is { } requires)
        {
            block.Append("requires_openai_auth = ").Append(requires ? "true" : "false").Append('\n');
        }

        if (!string.IsNullOrEmpty(wireApi))
        {
            block.Append("wire_api = ").Append(Quoted(wireApi)).Append('\n');
        }

        block.Append("base_url = ").Append(Quoted(address)).Append('\n');

        var rewritten = text.EndsWith('\n') ? text : text + "\n";
        rewritten += block.ToString();

        return WriteOutcome(rewritten, text, configPath, backupDirectory, null, address);
    }

    /// <summary>
    /// Restores the <c>base_url</c> of one <c>[model_providers.&lt;name&gt;]</c> section.
    /// </summary>
    /// <remarks>
    /// Codex's own rewrite drops keys it does not recognise — a relay's <c>base_url</c>
    /// disappears while the section header and its other keys survive. Since the address
    /// is what makes a relay account work at all, it has to be recoverable from somewhere
    /// that outlives that rewrite.
    /// </remarks>
    public static ConfigEditOutcome SetProviderBaseUrl(
        string rawUrl,
        string forProvider,
        string configPath,
        string? backupDirectory = null)
    {
        var address = rawUrl.Trim();
        if (address.Length == 0 || forProvider.Length == 0)
        {
            return ConfigEditOutcome.Failed("invalid_argument");
        }

        if (!File.Exists(configPath))
        {
            return ConfigEditOutcome.Unchanged;
        }

        var text = TryRead(configPath);
        if (text is null)
        {
            return ConfigEditOutcome.Failed("config_unreadable");
        }

        // Only touch the section for this provider; a same-named key elsewhere is
        // another provider's business.
        if (SectionRange(forProvider, text) is not { } range)
        {
            return ConfigEditOutcome.Failed("provider_missing");
        }

        var section = text[range.Start..range.End];
        var existing = ExistingBaseUrl(section);
        if (existing == address)
        {
            return ConfigEditOutcome.Unchanged;
        }

        var rewritten = ReplacingBaseUrl(text, range, address);
        return WriteOutcome(rewritten, text, configPath, backupDirectory, existing, address);
    }

    /// <summary>
    /// Writes one <c>[model_providers.&lt;name&gt;]</c> field, leaving the rest of the
    /// section alone.
    /// </summary>
    /// <remarks>
    /// A relay's section is created by whichever tool set that provider up, and those
    /// fields decide whether requests work at all (<c>wire_api</c>, and whether the
    /// endpoint wants the ChatGPT auth flow). Restoring only <c>base_url</c> left the
    /// others as whatever the last writer left behind.
    /// </remarks>
    public static ConfigEditOutcome SetProviderField(
        string? name,
        string key,
        string? value,
        string configPath,
        string? backupDirectory = null)
    {
        if (name is null || name.Length == 0 || key.Length == 0)
        {
            return ConfigEditOutcome.Failed("invalid_argument");
        }

        var address = value?.Trim();
        if (string.IsNullOrEmpty(address))
        {
            return ConfigEditOutcome.Unchanged;
        }

        var text = TryRead(configPath);
        if (text is null)
        {
            return ConfigEditOutcome.Failed("config_unreadable");
        }

        if (SectionRange(name, text) is not { } range)
        {
            return ConfigEditOutcome.Failed("provider_missing");
        }

        var existing = CodexConfigReader
            .SectionValues($"model_providers.{name}", text)
            .TryGetValue(key, out var found) ? found : null;
        if (existing == address)
        {
            return ConfigEditOutcome.Unchanged;
        }

        var rewritten = SettingKey(key, address, range, text);
        return WriteOutcome(rewritten, text, configPath, backupDirectory, existing, address);
    }

    /// <summary>
    /// Collapses duplicate sections, keeping the last declaration's values.
    /// </summary>
    /// <remarks>
    /// Codex reads the last table, so the earlier ones are dead weight that make the file
    /// lie about where a value comes from.
    /// </remarks>
    public static ConfigEditOutcome CollapseDuplicateSections(
        string name,
        string configPath,
        string? backupDirectory = null)
    {
        var text = TryRead(configPath);
        if (text is null)
        {
            return ConfigEditOutcome.Failed("config_unreadable");
        }

        var ranges = SectionRanges(name, text);
        if (ranges.Count <= 1)
        {
            return ConfigEditOutcome.Unchanged;
        }

        // Keep the last; drop the earlier ones entirely. Removed back-to-front so the
        // remaining offsets stay valid.
        var result = text;
        for (var i = ranges.Count - 2; i >= 0; i--)
        {
            result = result.Remove(ranges[i].Start, ranges[i].End - ranges[i].Start);
        }

        // Tidy any blank run the removal left behind.
        while (result.Contains("\n\n\n", StringComparison.Ordinal))
        {
            result = result.Replace("\n\n\n", "\n\n", StringComparison.Ordinal);
        }

        return WriteOutcome(
            result, text, configPath, backupDirectory,
            $"{ranges.Count} sections", "1");
    }

    /// <summary>
    /// Top-level keys a relay sets that must not survive a switch to an official account.
    /// </summary>
    /// <remarks>
    /// A relay points Codex at its own model list, so it writes <c>model_catalog_json</c>
    /// and matching context-window limits. Those are relay facts, not user preferences:
    /// left in place, an official account keeps resolving models from a five-entry relay
    /// catalog and inherits a context window belonging to someone else's endpoint. Codex
    /// never clears them (it re-serializes around them), so the switch has to.
    /// </remarks>
    public static readonly IReadOnlyList<string> RelayOwnedModelKeys = new[]
    {
        "model_catalog_json",
        "model_context_window",
        "model_max_context_window",
        "model_auto_compact_token_limit",
    };

    /// <summary>
    /// Drops an unloadable <c>model_catalog_json</c> so a relay account falls back to
    /// Codex's own model list.
    /// </summary>
    public static ConfigEditOutcome ClearInertModelCatalog(
        string configPath,
        string? backupDirectory = null)
    {
        if (!File.Exists(configPath))
        {
            return ConfigEditOutcome.Unchanged;
        }

        var text = TryRead(configPath);
        if (text is null)
        {
            return ConfigEditOutcome.Failed("config_unreadable");
        }

        var current = TopLevelValue("model_catalog_json", text);
        if (current is null || !IsInertCatalogPath(current))
        {
            return ConfigEditOutcome.Unchanged;
        }

        if (RemovingTopLevelKeys(new[] { "model_catalog_json" }, text) is not { } rewritten)
        {
            return ConfigEditOutcome.Unchanged;
        }

        return WriteOutcome(rewritten, text, configPath, backupDirectory, current, null);
    }

    /// <summary>Removes <see cref="RelayOwnedModelKeys"/> from the top-level preamble.</summary>
    public static ConfigEditOutcome ClearRelayModelKeys(
        string configPath,
        string? backupDirectory = null)
    {
        if (!File.Exists(configPath))
        {
            return ConfigEditOutcome.Unchanged;
        }

        var text = TryRead(configPath);
        if (text is null)
        {
            return ConfigEditOutcome.Failed("config_unreadable");
        }

        if (RemovingTopLevelKeys(RelayOwnedModelKeys, text) is not { } rewritten)
        {
            return ConfigEditOutcome.Unchanged;
        }

        return WriteOutcome(
            rewritten, text, configPath, backupDirectory,
            string.Join(',', RelayOwnedModelKeys), null);
    }

    /// <summary>The context-window preamble this tool applies to every account.</summary>
    /// <remarks>
    /// One window for all models on purpose. The bundled catalog advertises 272k for the
    /// current models, but the endpoints actually accept more, and a per-model figure
    /// would have to be refreshed every time the catalog changes. A single explicit value
    /// also stops a switcher's stale number (618k, 1000k) or a relay's own figure from
    /// silently deciding how much history Codex keeps.
    /// </remarks>
    public sealed record ContextWindow(int Window, double CompactFraction, int? Maximum = null)
    {
        /// <summary>400k with compaction at 90%.</summary>
        public static readonly ContextWindow Standard = new(400_000, 0.9);

        public int MaxWindow { get; init; } = Maximum ?? Window;

        /// <summary>
        /// The token count Codex compacts at, derived rather than hardcoded so the two
        /// values can never drift apart. Midpoint rounding matches Swift's
        /// <c>rounded()</c>, which rounds half away from zero.
        /// </summary>
        public int CompactLimit => (int)Math.Round(Window * CompactFraction, MidpointRounding.AwayFromZero);

        /// <summary>The keys this writes, in the order they are written.</summary>
        internal IReadOnlyList<(string Key, int Value)> Entries => new[]
        {
            ("model_context_window", Window),
            ("model_max_context_window", MaxWindow),
            ("model_auto_compact_token_limit", CompactLimit),
        };
    }

    /// <summary>
    /// Writes the context-window preamble, replacing any existing values.
    /// </summary>
    /// <remarks>
    /// Rewrites rather than appends: a switcher tool leaves its own numbers here, and a
    /// duplicate key would make Codex's behaviour depend on which line it reads first.
    /// </remarks>
    public static ConfigEditOutcome SetContextWindow(
        ContextWindow settings,
        string configPath,
        string? backupDirectory = null)
    {
        if (!File.Exists(configPath))
        {
            return ConfigEditOutcome.Unchanged;
        }

        var text = TryRead(configPath);
        if (text is null)
        {
            return ConfigEditOutcome.Failed("config_unreadable");
        }

        var previous = string.Join(
            ',',
            settings.Entries
                .Select(entry => TopLevelValue(entry.Key, text))
                .Where(value => value is not null));

        var alreadyApplied = settings.Entries.All(entry =>
        {
            var value = TopLevelValue(entry.Key, text);
            return value is not null
                && CodexConfigReader.Unquote(value).Trim() == entry.Value.ToString();
        });
        if (alreadyApplied)
        {
            return ConfigEditOutcome.Unchanged;
        }

        var rewritten = text;
        foreach (var (key, value) in settings.Entries)
        {
            rewritten = SettingTopLevelKey(key, value.ToString(), rewritten);
        }

        return WriteOutcome(
            rewritten, text, configPath, backupDirectory,
            previous,
            string.Join(',', settings.Entries.Select(entry => entry.Value)));
    }

    /// <summary>Sets the top-level <c>model</c>.</summary>
    public static ConfigEditOutcome SetSelectedModel(
        string model,
        string configPath,
        string? backupDirectory = null)
        => SetTopLevelKey("model", model, configPath, backupDirectory);

    /// <summary>Sets one preamble key to a string value.</summary>
    public static ConfigEditOutcome SetTopLevelKey(
        string key,
        string value,
        string configPath,
        string? backupDirectory = null)
    {
        var text = TryRead(configPath);
        if (text is null)
        {
            return ConfigEditOutcome.Failed("config_unreadable");
        }

        var previous = CodexConfigReader.TopLevelValues(text)
            .TryGetValue(key, out var found) ? found : null;
        if (previous == value)
        {
            return ConfigEditOutcome.Unchanged;
        }

        var rewritten = SettingTopLevelKey(key, Quoted(value), text);
        return WriteOutcome(rewritten, text, configPath, backupDirectory, previous, value);
    }

    // ------------------------------------------------------------------ internals

    /// <summary>
    /// Character range of a <c>[model_providers.&lt;name&gt;]</c> section body, header
    /// included.
    /// </summary>
    /// <remarks>
    /// When a file declares the same section twice — which a sequence of tools rewriting
    /// the same file does produce — later declarations override earlier ones, because
    /// that is how a TOML reader resolves duplicate tables. Writing into the first would
    /// edit a section Codex ignores, so the <i>last</i> one is returned.
    /// </remarks>
    internal static (int Start, int End)? SectionRange(string name, string text)
    {
        var all = SectionRanges(name, text);
        // The effective section: a later duplicate wins.
        return all.Count > 0 ? all[^1] : null;
    }

    /// <summary>Every declaration of <c>[model_providers.&lt;name&gt;]</c>, in file order.</summary>
    internal static List<(int Start, int End)> SectionRanges(string name, string text)
    {
        var header = $"[model_providers.{name}]";
        var subHeaderPrefix = $"[model_providers.{name}.";
        var ranges = new List<(int Start, int End)>();
        int? start = null;
        var index = 0;

        void Close(int end)
        {
            if (start is { } opened)
            {
                ranges.Add((opened, end));
            }

            start = null;
        }

        while (index < text.Length)
        {
            var newline = text.IndexOf('\n', index);
            var lineEnd = newline < 0 ? text.Length : newline;
            var trimmed = text[index..lineEnd].Trim();
            if (trimmed.StartsWith('['))
            {
                if (start is not null)
                {
                    // A sub-table of ours does not end the section; any other header,
                    // including a repeat of the same one, does.
                    if (!trimmed.StartsWith(subHeaderPrefix, StringComparison.Ordinal))
                    {
                        Close(index);
                        if (trimmed == header || trimmed.StartsWith(header + " ", StringComparison.Ordinal))
                        {
                            start = index;
                        }
                    }
                }
                else if (trimmed == header || trimmed.StartsWith(header + " ", StringComparison.Ordinal))
                {
                    start = index;
                }
            }

            if (lineEnd >= text.Length)
            {
                break;
            }

            index = lineEnd + 1;
        }

        Close(text.Length);
        return ranges;
    }

    internal static string? ExistingBaseUrl(string section)
    {
        foreach (var raw in section.Split('\n'))
        {
            var cleaned = CodexConfigReader.StripComment(raw).Trim();
            var kv = CodexConfigReader.KeyValue(cleaned);
            if (kv is null || kv.Value.Key != "base_url")
            {
                continue;
            }

            return CodexConfigReader.Unquote(kv.Value.Value).Trim();
        }

        return null;
    }

    private static string ReplacingBaseUrl(string text, (int Start, int End) section, string address)
    {
        var body = text[section.Start..section.End];
        var lines = body.Split('\n').ToList();
        var replaced = false;
        for (var i = 0; i < lines.Count; i++)
        {
            var cleaned = CodexConfigReader.StripComment(lines[i]).Trim();
            var kv = CodexConfigReader.KeyValue(cleaned);
            if (kv is null || kv.Value.Key != "base_url")
            {
                continue;
            }

            lines[i] = $"base_url = {Quoted(address)}";
            replaced = true;
            break;
        }

        if (!replaced)
        {
            // No address line survived the rewrite: put one directly under the header so
            // the section reads normally.
            if (lines.Count > 1)
            {
                lines.Insert(1, $"base_url = {Quoted(address)}");
            }
            else
            {
                lines.Add($"base_url = {Quoted(address)}");
            }
        }

        return string.Concat(
            text.AsSpan(0, section.Start),
            string.Join('\n', lines),
            text.AsSpan(section.End));
    }

    /// <summary>
    /// <c>model_catalog_json</c> values that are dead weight rather than a real choice.
    /// </summary>
    /// <remarks>
    /// The relay tooling writes a <i>relative</i> path, which Codex resolves against its
    /// working directory rather than <c>.codex</c>. It therefore never loads: launching
    /// with that value fails outright, so Codex has always fallen back to its bundled
    /// catalog. Such a value changes nothing and is removed so the intent is honest.
    /// </remarks>
    internal static bool IsInertCatalogPath(string value)
    {
        var unquoted = CodexConfigReader.Unquote(value).Trim();
        if (unquoted.Length == 0)
        {
            return false;
        }

        // Only a bare relative path is inert; anything absolute or home-rooted is a
        // deliberate, loadable choice and is left alone.
        if (unquoted.StartsWith('/') || unquoted.StartsWith('~'))
        {
            return false;
        }

        if (unquoted.StartsWith("./", StringComparison.Ordinal)
            || unquoted.StartsWith("../", StringComparison.Ordinal))
        {
            return false;
        }

        // A Windows drive-letter path is absolute too, and must not be treated as inert.
        return !WindowsAbsolutePath().IsMatch(unquoted);
    }

    /// <summary>The preamble's value for <paramref name="key"/>, or null when absent.</summary>
    internal static string? TopLevelValue(string key, string text)
    {
        var inSection = false;
        foreach (var raw in text.Split('\n'))
        {
            var cleaned = CodexConfigReader.StripComment(raw).Trim();
            if (cleaned.StartsWith('['))
            {
                inSection = true;
            }

            if (inSection)
            {
                continue;
            }

            var kv = CodexConfigReader.KeyValue(cleaned);
            if (kv is not null && kv.Value.Key == key)
            {
                return kv.Value.Value;
            }
        }

        return null;
    }

    /// <summary>Drops the named keys from the preamble, or null when none were present.</summary>
    /// <remarks>
    /// Only the preamble is touched. The same names can legitimately appear inside a
    /// <c>[profiles.*]</c> or project table, where they are that table's own settings.
    /// </remarks>
    internal static string? RemovingTopLevelKeys(IReadOnlyList<string> keys, string text)
    {
        var wanted = new HashSet<string>(keys, StringComparer.Ordinal);
        var removed = false;
        var inSection = false;
        var kept = new List<string>();

        foreach (var raw in text.Split('\n'))
        {
            var cleaned = CodexConfigReader.StripComment(raw).Trim();
            if (cleaned.StartsWith('['))
            {
                inSection = true;
            }

            if (!inSection)
            {
                var kv = CodexConfigReader.KeyValue(cleaned);
                if (kv is not null && wanted.Contains(kv.Value.Key))
                {
                    removed = true;
                    continue;
                }
            }

            kept.Add(raw);
        }

        return removed ? string.Join('\n', kept) : null;
    }

    /// <summary>Sets <c>key = value</c> inside a section, replacing all occurrences there.</summary>
    internal static string SettingKey(string key, string value, (int Start, int End) range, string text)
    {
        var body = text[range.Start..range.End];
        var lines = body.Split('\n').ToList();
        int? firstIndex = null;
        var duplicates = new List<int>();

        for (var i = 0; i < lines.Count; i++)
        {
            var cleaned = CodexConfigReader.StripComment(lines[i]).Trim();
            // Line 0 is the section's own `[header]`. Skipping only that one, rather than
            // breaking on any `[`, is what lets the scan reach the section's keys: a later
            // `[` really is a sub-table and does end them.
            if (i > 0 && cleaned.StartsWith('['))
            {
                break;
            }

            var kv = CodexConfigReader.KeyValue(cleaned);
            if (kv is null || kv.Value.Key != key)
            {
                continue;
            }

            if (firstIndex is null)
            {
                firstIndex = i;
            }
            else
            {
                duplicates.Add(i);
            }
        }

        foreach (var index in Enumerable.Reverse(duplicates))
        {
            lines.RemoveAt(index);
        }

        var replacement = $"{key} = {TomlValue(value)}";
        if (firstIndex is { } at)
        {
            lines[at] = replacement;
        }
        else if (lines.Count > 1)
        {
            lines.Insert(1, replacement);
        }
        else
        {
            lines.Add(replacement);
        }

        return string.Concat(
            text.AsSpan(0, range.Start),
            string.Join('\n', lines),
            text.AsSpan(range.End));
    }

    /// <summary>
    /// Sets one preamble key, replacing every existing occurrence.
    /// </summary>
    /// <remarks>
    /// All duplicates are removed before the new value goes in at the first occurrence's
    /// position, so a file that already had the key twice ends up with exactly one.
    /// </remarks>
    internal static string SettingTopLevelKey(string key, string value, string text)
    {
        var lines = text.Split('\n').ToList();
        var inSection = false;
        int? firstIndex = null;
        var duplicates = new List<int>();

        for (var i = 0; i < lines.Count; i++)
        {
            var line = CodexConfigReader.StripComment(lines[i]).Trim();
            if (line.StartsWith('['))
            {
                inSection = true;
                continue;
            }

            var kv = CodexConfigReader.KeyValue(line);
            if (inSection || kv is null || kv.Value.Key != key)
            {
                continue;
            }

            if (firstIndex is null)
            {
                firstIndex = i;
            }
            else
            {
                duplicates.Add(i);
            }
        }

        // Remove later duplicates first so the earlier indices stay valid.
        foreach (var index in Enumerable.Reverse(duplicates))
        {
            lines.RemoveAt(index);
        }

        var replacement = $"{key} = {value}";
        if (firstIndex is { } at)
        {
            lines[at] = replacement;
        }
        else
        {
            // No such key yet: place it after the last existing preamble line, so it
            // joins the other top-level settings instead of landing above them.
            var insertAt = 0;
            for (var i = 0; i < lines.Count; i++)
            {
                var line = CodexConfigReader.StripComment(lines[i]).Trim();
                if (line.StartsWith('['))
                {
                    break;
                }

                if (line.Length > 0)
                {
                    insertAt = i + 1;
                }
            }

            lines.Insert(insertAt, replacement);
        }

        return string.Join('\n', lines);
    }

    /// <summary>
    /// Replaces or removes the <c>model_provider</c> key that appears before the first
    /// <c>[section]</c> header. A <c>model_provider</c> inside a section belongs to that
    /// section and is left alone.
    /// </summary>
    internal static string ReplacingTopLevelProvider(string text, string? name)
    {
        var lines = text.Split('\n').ToList();
        var inSection = false;
        var replaced = false;
        int? insertAt = null;

        for (var i = 0; i < lines.Count; i++)
        {
            var line = CodexConfigReader.StripComment(lines[i]).Trim();
            if (line.Length == 0)
            {
                continue;
            }

            if (line.StartsWith('['))
            {
                inSection = true;
                insertAt ??= i;
                continue;
            }

            if (inSection)
            {
                continue;
            }

            var kv = CodexConfigReader.KeyValue(line);
            if (kv is null || kv.Value.Key != "model_provider")
            {
                continue;
            }

            if (name is not null)
            {
                lines[i] = $"model_provider = {Quoted(name)}";
            }
            else
            {
                lines.RemoveAt(i);
            }

            replaced = true;
            break;
        }

        if (!replaced && name is not null)
        {
            // No top-level key yet: put it at the very top, ahead of the first section, so
            // the file keeps reading as a flat preamble.
            lines.Insert(insertAt ?? 0, $"model_provider = {Quoted(name)}");
        }

        return string.Join('\n', lines);
    }

    /// <summary>
    /// Formats a value for a TOML assignment.
    /// </summary>
    /// <remarks>
    /// Quoting everything is the trap this avoids: <c>supports_websockets = "false"</c> is
    /// a <i>string</i>, not the boolean Codex expects, and the mismatch makes the whole
    /// config unreadable — Codex then asks for a login instead of starting a
    /// conversation. Booleans and numbers are written bare; everything else is quoted.
    /// </remarks>
    internal static string TomlValue(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed is "true" or "false")
        {
            return trimmed;
        }

        // An integer or decimal, with an optional sign, and nothing else in between.
        return BareNumber().IsMatch(trimmed) ? trimmed : Quoted(raw);
    }

    internal static string Quoted(string name)
        => "\"" + name.Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";

    private static ConfigEditOutcome WriteOutcome(
        string rewritten,
        string original,
        string configPath,
        string? backupDirectory,
        string? previous,
        string? current)
    {
        try
        {
            Backup(original, backupDirectory ?? DefaultBackupDirectory);
        }
        catch (IOException)
        {
            return ConfigEditOutcome.Failed("config_backup_failed");
        }
        catch (UnauthorizedAccessException)
        {
            return ConfigEditOutcome.Failed("config_backup_failed");
        }

        try
        {
            AtomicWrite(rewritten, configPath);
        }
        catch (IOException)
        {
            return ConfigEditOutcome.Failed("config_write_failed");
        }
        catch (UnauthorizedAccessException)
        {
            return ConfigEditOutcome.Failed("config_write_failed");
        }

        return ConfigEditOutcome.Updated(previous, current);
    }

    private static void Backup(string text, string directory)
    {
        Directory.CreateDirectory(directory);
        var name = $"config.toml.{Guid.NewGuid():N}.bak";
        AtomicWrite(text, Path.Combine(directory, name));
    }

    /// <summary>
    /// Writes through a temporary file in the same directory, then moves it into place.
    /// </summary>
    /// <remarks>
    /// A move within one directory is atomic on both NTFS and POSIX filesystems, so a
    /// crash mid-write leaves either the old file or the new one — never a half-written
    /// config that Codex cannot parse.
    /// <para>
    /// The macOS original also <c>chmod</c>s the file to 0600. Windows has no equivalent
    /// mode bit: protection comes from the ACL on the user profile, which already excludes
    /// other non-administrative users. Tightening it explicitly is left to the app layer,
    /// where the decision can be made knowingly.
    /// </para>
    /// </remarks>
    internal static void AtomicWrite(string text, string path)
    {
        var directory = Path.GetDirectoryName(path);
        if (string.IsNullOrEmpty(directory))
        {
            directory = ".";
        }

        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(
            directory,
            $".{Path.GetFileName(path)}.runway-{Guid.NewGuid():N}");

        try
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            using (var stream = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporary, path, overwrite: true);
        }
        catch
        {
            if (File.Exists(temporary))
            {
                try
                {
                    File.Delete(temporary);
                }
                catch (IOException)
                {
                    // The original failure is the one worth reporting.
                }
            }

            throw;
        }
    }

    private static string? TryRead(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            return File.ReadAllText(path, Encoding.UTF8);
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    [GeneratedRegex(@"^-?[0-9]+(\.[0-9]+)?$")]
    private static partial Regex BareNumber();

    [GeneratedRegex(@"^[A-Za-z]:[\\/]|^\\\\")]
    private static partial Regex WindowsAbsolutePath();
}
