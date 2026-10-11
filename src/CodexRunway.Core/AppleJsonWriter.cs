using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace CodexRunway.Core;

/// <summary>
/// Serialises a JSON object the way Apple's <c>JSONSerialization</c> does with
/// <c>[.prettyPrinted, .sortedKeys]</c>.
/// </summary>
/// <remarks>
/// <para>
/// This is hand-written because .NET cannot be configured to match. A credential file is
/// shared between the macOS and Windows builds, so a different byte sequence means the same
/// logical file churns in every diff and checksum comparison between them.
/// </para>
/// <para>
/// Every rule below was established by probing <c>JSONSerialization</c> on macOS, not
/// inferred:
/// </para>
/// <list type="bullet">
/// <item><description>Two-space indent; a space on both sides of <c>:</c>.</description></item>
/// <item><description>An empty object is <c>{\n\n}</c> and an empty array <c>[\n\n]</c> —
/// Apple emits a newline between the braces even with nothing inside.</description></item>
/// <item><description>Keys are sorted recursively, case-insensitively and
/// numerically.</description></item>
/// <item><description><c>/</c> is escaped as <c>\/</c>. <c>U+007F</c>, <c>U+00A0</c>,
/// <c>U+2028</c> and <c>U+2029</c> are emitted raw, and non-BMP characters stay as UTF-8
/// rather than being split into surrogate escapes.</description></item>
/// <item><description>A whole-number double prints without a decimal point
/// (<c>10000000000</c>), and a fractional one prints with full round-trip precision
/// (<c>0.90000000000000002</c>).</description></item>
/// <item><description>Output ends with the closing brace and no trailing
/// newline.</description></item>
/// </list>
/// </remarks>
internal static class AppleJsonWriter
{
    public static string Write(JsonObject root)
    {
        var builder = new StringBuilder();
        WriteValue(builder, SortKeysDeep(root), indent: 0);
        return builder.ToString();
    }

    /// <summary>Rebuilds the graph with every level's keys in Apple's order.</summary>
    private static JsonNode? SortKeysDeep(JsonNode? node)
    {
        switch (node)
        {
            case JsonObject obj:
                var rebuilt = new JsonObject();
                foreach (var pair in obj.OrderBy(p => p.Key, AppleKeyComparer.Instance))
                {
                    rebuilt[pair.Key] = SortKeysDeep(pair.Value);
                }

                return rebuilt;
            case JsonArray array:
                var items = new JsonArray();
                foreach (var item in array)
                {
                    items.Add(SortKeysDeep(item));
                }

                return items;
            default:
                return node?.DeepClone();
        }
    }

    private static void WriteValue(StringBuilder builder, JsonNode? node, int indent)
    {
        switch (node)
        {
            case null:
                builder.Append("null");
                break;
            case JsonObject obj:
                WriteObject(builder, obj, indent);
                break;
            case JsonArray array:
                WriteArray(builder, array, indent);
                break;
            default:
                WriteScalar(builder, node);
                break;
        }
    }

    private static void WriteObject(StringBuilder builder, JsonObject obj, int indent)
    {
        if (obj.Count == 0)
        {
            // Apple writes a newline even with no members.
            builder.Append('{').Append('\n').Append('\n').Append(Pad(indent)).Append('}');
            return;
        }

        builder.Append('{');
        var first = true;
        foreach (var pair in obj)
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            builder.Append('\n').Append(Pad(indent + 1));
            WriteString(builder, pair.Key);
            builder.Append(" : ");
            WriteValue(builder, pair.Value, indent + 1);
        }

        builder.Append('\n').Append(Pad(indent)).Append('}');
    }

    private static void WriteArray(StringBuilder builder, JsonArray array, int indent)
    {
        if (array.Count == 0)
        {
            builder.Append('[').Append('\n').Append('\n').Append(Pad(indent)).Append(']');
            return;
        }

        builder.Append('[');
        var first = true;
        foreach (var item in array)
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            builder.Append('\n').Append(Pad(indent + 1));
            WriteValue(builder, item, indent + 1);
        }

        builder.Append('\n').Append(Pad(indent)).Append(']');
    }

    private static void WriteScalar(StringBuilder builder, JsonNode node)
    {
        switch (node.GetValueKind())
        {
            case System.Text.Json.JsonValueKind.True:
                builder.Append("true");
                break;
            case System.Text.Json.JsonValueKind.False:
                builder.Append("false");
                break;
            case System.Text.Json.JsonValueKind.Null:
                builder.Append("null");
                break;
            case System.Text.Json.JsonValueKind.String:
                WriteString(builder, node.GetValue<string>());
                break;
            case System.Text.Json.JsonValueKind.Number:
                builder.Append(FormatNumber(node));
                break;
            default:
                throw new CodexAuthFormatException(
                    $"unsupported JSON node kind: {node.GetValueKind()}");
        }
    }

    /// <summary>
    /// Formats a number the way Apple does: integers bare, floating-point values at 17
    /// significant digits with a lowercase exponent.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <c>JSONSerialization</c> prints doubles with <c>%.17g</c>, which is <i>not</i> the
    /// shortest representation that round-trips. The difference is visible: Apple writes
    /// <c>0.9</c> as <c>0.90000000000000002</c> and <c>0.05</c> as
    /// <c>0.050000000000000003</c>, where .NET's <c>"R"</c> would write <c>0.9</c> and
    /// <c>0.05</c>. That matters because the account index carries money as doubles, so
    /// using the shorter form would stop the file being byte-identical.
    /// </para>
    /// <para>
    /// <c>G17</c> matches <c>%.17g</c> exactly except that .NET writes the exponent as
    /// <c>E</c> where C writes <c>e</c>, which is normalised below.
    /// </para>
    /// </remarks>
    private static string FormatNumber(JsonNode node)
    {
        var element = node.GetValue<System.Text.Json.JsonElement>();

        if (element.TryGetInt64(out var integer))
        {
            return integer.ToString(CultureInfo.InvariantCulture);
        }

        var value = element.GetDouble();
        if (double.IsNaN(value) || double.IsInfinity(value))
        {
            throw new CodexAuthFormatException("NaN and Infinity are not valid JSON numbers");
        }

        return value.ToString("G17", CultureInfo.InvariantCulture)
            .Replace('E', 'e');
    }

    /// <summary>
    /// Writes a JSON string literal with Apple's escaping rules.
    /// </summary>
    /// <remarks>
    /// The character classes are the ones established by probing: the usual short escapes,
    /// <c>\u00xx</c> for other control characters, <c>\/</c> for a solidus, and everything
    /// else — including <c>U+007F</c>, <c>U+00A0</c>, <c>U+2028</c>, <c>U+2029</c> and
    /// non-BMP characters — passed through as UTF-8.
    /// </remarks>
    private static void WriteString(StringBuilder builder, string value)
    {
        builder.Append('"');
        foreach (var rune in value.EnumerateRunes())
        {
            switch (rune.Value)
            {
                case '"':
                    builder.Append("\\\"");
                    break;
                case '\\':
                    builder.Append("\\\\");
                    break;
                case '/':
                    builder.Append("\\/");
                    break;
                case '\b':
                    builder.Append("\\b");
                    break;
                case '\f':
                    builder.Append("\\f");
                    break;
                case '\n':
                    builder.Append("\\n");
                    break;
                case '\r':
                    builder.Append("\\r");
                    break;
                case '\t':
                    builder.Append("\\t");
                    break;
                default:
                    if (rune.Value < 0x20)
                    {
                        builder.Append("\\u")
                            .Append(rune.Value.ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        // Appending the rune keeps non-BMP characters as one UTF-8
                        // sequence instead of a surrogate pair.
                        builder.Append(rune.ToString());
                    }

                    break;
            }
        }

        builder.Append('"');
    }

    private static string Pad(int indent) => new(' ', indent * 2);

    /// <summary>
    /// Apple's key ordering: case-insensitive, with a numeric-aware comparison so
    /// <c>a2</c> sorts before <c>a10</c>.
    /// </summary>
    private sealed class AppleKeyComparer : IComparer<string>
    {
        public static readonly AppleKeyComparer Instance = new();

        public int Compare(string? x, string? y)
        {
            if (x is null || y is null)
            {
                return string.CompareOrdinal(x, y);
            }

            var i = 0;
            var j = 0;
            while (i < x.Length && j < y.Length)
            {
                var cx = x[i];
                var cy = y[j];

                if (char.IsAsciiDigit(cx) && char.IsAsciiDigit(cy))
                {
                    // Compare the full digit runs as numbers so 2 < 10.
                    var si = i;
                    var sj = j;
                    while (i < x.Length && char.IsAsciiDigit(x[i]))
                    {
                        i++;
                    }

                    while (j < y.Length && char.IsAsciiDigit(y[j]))
                    {
                        j++;
                    }

                    var nx = x[si..i].TrimStart('0');
                    var ny = y[sj..j].TrimStart('0');
                    if (nx.Length != ny.Length)
                    {
                        return nx.Length - ny.Length;
                    }

                    var digits = string.CompareOrdinal(nx, ny);
                    if (digits != 0)
                    {
                        return digits;
                    }

                    continue;
                }

                var lower = char.ToLowerInvariant(cx).CompareTo(char.ToLowerInvariant(cy));
                if (lower != 0)
                {
                    return lower;
                }

                i++;
                j++;
            }

            return (x.Length - i) - (y.Length - j);
        }
    }
}
