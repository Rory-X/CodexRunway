using System.Text;

namespace CodexRunway.Core;

/// <summary>
/// Minimal reader for the <c>[model_providers.&lt;name&gt;]</c> sections of Codex's
/// <c>config.toml</c>.
/// </summary>
/// <remarks>
/// Ported from the macOS app's <c>CodexConfigReader</c>. A full TOML parser is not
/// warranted: the app needs exactly one thing from this file — which provider names map
/// to which <c>base_url</c>, so a managed account can be matched to the relay it actually
/// talks to. Anything the parser does not understand is skipped rather than guessed at.
/// </remarks>
public static class CodexConfigReader
{
    /// <summary>The default config location, which mirrors Codex's own layout.</summary>
    public static string DefaultConfigPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".codex",
        "config.toml");

    /// <summary>Provider name to base URL, in file order.</summary>
    public static IReadOnlyDictionary<string, string> ProviderBaseUrls(string configPath)
        => ProviderBaseUrlsFromToml(ReadText(configPath));

    /// <summary>The provider currently selected by <c>model_provider</c>, when present.</summary>
    public static string? SelectedProvider(string configPath)
        => SelectedProviderFromToml(ReadText(configPath));

    public static string? SelectedProviderFromToml(string toml)
    {
        string? currentSection = null;
        foreach (var rawLine in SplitLines(toml))
        {
            var line = StripComment(rawLine).Trim();
            if (line.Length == 0)
            {
                continue;
            }

            if (line.StartsWith('['))
            {
                currentSection = SectionName(line);
                continue;
            }

            // Only a top-level key counts; a `model_provider` inside a section is a
            // provider's own setting, not the selection.
            if (currentSection is not null)
            {
                continue;
            }

            if (KeyValue(line) is not var (key, value) || key != "model_provider")
            {
                continue;
            }

            return Unquote(value);
        }

        return null;
    }

    public static IReadOnlyDictionary<string, string> ProviderBaseUrlsFromToml(string toml)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        string? currentProvider = null;

        foreach (var rawLine in SplitLines(toml))
        {
            var line = StripComment(rawLine).Trim();
            if (line.Length == 0)
            {
                continue;
            }

            if (line.StartsWith('['))
            {
                currentProvider = ProviderNameFromSection(SectionName(line));
                continue;
            }

            if (currentProvider is null
                || KeyValue(line) is not var (key, value)
                || key != "base_url")
            {
                continue;
            }

            var url = Unquote(value).Trim();
            if (url.Length > 0)
            {
                result[currentProvider] = url;
            }
        }

        return result;
    }

    /// <summary>
    /// Every top-level <c>key = value</c> in the file's preamble, excluding sections.
    /// </summary>
    /// <remarks>
    /// Used to capture an account's own settings before another tool rewrites the file.
    /// Only the preamble is read: a key inside <c>[profiles.*]</c> or a provider section
    /// belongs to that table, not to the account.
    /// </remarks>
    public static IReadOnlyDictionary<string, string> TopLevelValues(string toml)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var rawLine in SplitLines(toml))
        {
            var line = StripComment(rawLine).Trim();
            if (line.Length == 0)
            {
                continue;
            }

            if (line.StartsWith('['))
            {
                break;
            }

            if (KeyValue(line) is var (key2, value2))
            {
                result[key2] = Unquote(value2).Trim();
            }
        }

        return result;
    }

    /// <summary>The keys of one <c>[&lt;section&gt;]</c> table, header excluded.</summary>
    public static IReadOnlyDictionary<string, string> SectionValues(string section, string toml)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var inside = false;
        foreach (var rawLine in SplitLines(toml))
        {
            var line = StripComment(rawLine).Trim();
            if (line.Length == 0)
            {
                continue;
            }

            if (line.StartsWith('['))
            {
                // Any header other than the wanted one ends the search, including a
                // sub-table of it: only that table's own keys are reported.
                inside = SectionName(line) == section;
                continue;
            }

            if (inside && KeyValue(line) is var (key, value))
            {
                result[key] = Unquote(value).Trim();
            }
        }

        return result;
    }

    /// <summary>
    /// Provider names in the order their <c>[model_providers.&lt;name&gt;]</c> sections appear.
    /// </summary>
    /// <remarks>
    /// Callers that must pick a provider need a stable choice, and a dictionary gives
    /// them none: file order keeps the selection matching what the user sees at the top
    /// of their own config.
    /// </remarks>
    public static IReadOnlyList<string> ProviderNamesInFileOrder(string toml)
    {
        var names = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var rawLine in SplitLines(toml))
        {
            var line = StripComment(rawLine).Trim();
            if (!line.StartsWith('['))
            {
                continue;
            }

            if (ProviderNameFromSection(SectionName(line)) is not { } name)
            {
                continue;
            }

            if (seen.Add(name))
            {
                names.Add(name);
            }
        }

        return names;
    }

    public static IReadOnlyList<string> ProviderNamesInFileOrderFromFile(string configPath)
        => ProviderNamesInFileOrder(ReadText(configPath));

    // ---------------------------------------------------------------- line parsing

    /// <summary>
    /// The provider name when the section is <c>model_providers.&lt;name&gt;</c>; null for
    /// any other section (including the bare <c>[model_providers]</c>).
    /// </summary>
    internal static string? ProviderNameFromSection(string section)
    {
        var parts = section.Split('.');
        if (parts.Length < 2 || parts[0] != "model_providers")
        {
            return null;
        }

        // A quoted provider name may itself contain dots.
        var name = string.Join('.', parts.Skip(1));
        var trimmed = Unquote(name);
        return trimmed.Length == 0 ? null : trimmed;
    }

    internal static string SectionName(string line)
    {
        var text = line;
        if (text.StartsWith("[[", StringComparison.Ordinal))
        {
            text = text[2..];
        }
        else if (text.StartsWith('['))
        {
            text = text[1..];
        }

        if (text.EndsWith("]]", StringComparison.Ordinal))
        {
            text = text[..^2];
        }
        else if (text.EndsWith(']'))
        {
            text = text[..^1];
        }

        return text.Trim();
    }

    internal static (string Key, string Value)? KeyValue(string line)
    {
        var index = line.IndexOf('=');
        if (index < 0)
        {
            return null;
        }

        var key = line[..index].Trim();
        var value = line[(index + 1)..].Trim();
        return key.Length == 0 ? null : (key, value);
    }

    /// <summary>Drops a trailing <c>#</c> comment that is not inside a quoted string.</summary>
    internal static string StripComment(string line)
    {
        var inSingle = false;
        var inDouble = false;
        var escaped = false;
        var result = new StringBuilder(line.Length);

        foreach (var character in line)
        {
            if (escaped)
            {
                result.Append(character);
                escaped = false;
                continue;
            }

            switch (character)
            {
                case '\\' when inDouble:
                    result.Append(character);
                    escaped = true;
                    break;
                case '"' when !inSingle:
                    inDouble = !inDouble;
                    result.Append(character);
                    break;
                case '\'' when !inDouble:
                    inSingle = !inSingle;
                    result.Append(character);
                    break;
                case '#' when !inSingle && !inDouble:
                    return result.ToString();
                default:
                    result.Append(character);
                    break;
            }
        }

        return result.ToString();
    }

    internal static string Unquote(string value)
    {
        var text = value.Trim();
        if (text.Length >= 2 && text.StartsWith('"') && text.EndsWith('"'))
        {
            text = text[1..^1];
        }
        else if (text.Length >= 2 && text.StartsWith('\'') && text.EndsWith('\''))
        {
            text = text[1..^1];
        }

        return text;
    }

    /// <summary>
    /// Splits the file into lines, normalising CRLF.
    /// </summary>
    /// <remarks>
    /// Windows-authored <c>config.toml</c> files normally use CRLF. Every value read here
    /// is <c>Trim()</c>ed before use, so a stray <c>\r</c> would already be removed;
    /// normalising at the split keeps that guarantee in one place rather than depending
    /// on every future consumer remembering to trim.
    /// </remarks>
    private static IEnumerable<string> SplitLines(string text)
        => text.Split('\n').Select(line => line.EndsWith('\r') ? line[..^1] : line);

    private static string ReadText(string path)
        => File.Exists(path) ? File.ReadAllText(path, Encoding.UTF8) : string.Empty;
}
