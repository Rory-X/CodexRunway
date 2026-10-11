using CodexRunway.Core;

// A runnable check of the ported core, on whatever machine you are on.
//
// The unit tests prove correctness; this exists so a person can *see* the ported code
// work against real files and real credential shapes without a test runner. It never
// prints a secret: only shapes, counts, and verdicts.

var layout = RunwayPaths.FromEnvironment();
var store = new CredentialStore(layout);

Section("Environment");
Console.WriteLine("  runtime        " + Environment.Version);
Console.WriteLine("  os             " + System.Runtime.InteropServices.RuntimeInformation.OSDescription);
Console.WriteLine("  codex home     " + layout.CodexHome);
Console.WriteLine("  app home       " + layout.AppHome);
Console.WriteLine();

Section("Codex config (read-only)");
if (File.Exists(layout.ConfigPath))
{
    var text = File.ReadAllText(layout.ConfigPath);
    var providers = CodexConfigReader.ProviderBaseUrls(layout.ConfigPath);
    Console.WriteLine("  providers      " + providers.Count);
    foreach (var name in CodexConfigReader.ProviderNamesInFileOrder(text))
    {
        Console.WriteLine("    - " + name);
        Console.WriteLine("      base_url   " + providers[name]);
    }

    Console.WriteLine("  selected       " + (CodexConfigReader.SelectedProvider(layout.ConfigPath) ?? "(none)"));
    var preamble = CodexConfigReader.TopLevelValues(text);
    Console.WriteLine("  context window " + (preamble.TryGetValue("model_context_window", out var w) ? w : "(unset)"));
}
else
{
    Console.WriteLine("  (no config.toml - skipped)");
}

Console.WriteLine();
Section("Stored credentials (values never printed)");
var accounts = Directory.Exists(layout.AccountsDirectory)
    ? Directory.GetDirectories(layout.AccountsDirectory).OrderBy(d => d, StringComparer.Ordinal).ToArray()
    : Array.Empty<string>();
if (accounts.Length == 0)
{
    Console.WriteLine("  (none)");
}
else
{
    var usable = 0;
    foreach (var directory in accounts)
    {
        var id = Path.GetFileName(directory);
        try
        {
            var auth = store.LoadCredential(id);
            var kind = auth.IsApiKeyAuth ? "apiKey" : "oauth";
            var verdict = auth.GetLoginUsability();
            if (verdict == LoginUsability.Usable) { usable++; }
            Console.WriteLine("  " + id.PadRight(28) + " " + kind.PadRight(7) + " " + verdict);
        }
        catch (CredentialStoreException error)
        {
            Console.WriteLine("  " + id.PadRight(28) + " ??      " + error.Problem);
        }
    }

    Console.WriteLine("  " + accounts.Length + " stored, " + usable + " usable");
}

Console.WriteLine();
Section("Round-trip through the Apple-compatible writer");
// Built here rather than read from disk, so this runs on a machine with no data.
var sample = new CodexAuth
{
    AuthMode = "chatgpt",
    Tokens = new CodexTokens
    {
        AccessToken = new string('a', 48),
        // Deliberately contains a solidus: Apple escapes it as \/ and .NET does not, so
        // this value is what makes the escaping check meaningful.
        RefreshToken = "https://relay.example/v1",
        AccountId = "acct-selfcheck",
    },
};
var encoded = sample.ToOfficialJson();
var decoded = CodexAuth.Parse(encoded);
Console.WriteLine("  encoded        " + encoded.Length + " bytes, " + (encoded.Contains('\r') ? "CRLF" : "LF"));
Console.WriteLine("  tokens equal   " + (decoded.Tokens.AccessToken == sample.Tokens.AccessToken));
var slashEscaped = encoded.Contains("https:\\/\\/relay.example\\/v1", StringComparison.Ordinal);
Console.WriteLine("  slash escaped  " + slashEscaped);
if (!slashEscaped)
{
    Console.WriteLine("  !! the writer did not escape the solidus the way Apple does");
    return 1;
}
Console.WriteLine("  redacted       " + sample);
Console.WriteLine("  no leak        " + !sample.ToString().Contains(new string('a', 48), StringComparison.Ordinal));

Console.WriteLine();
Console.WriteLine("All checks completed.");
return 0;

static void Section(string title) => Console.WriteLine("-- " + title + " --");
