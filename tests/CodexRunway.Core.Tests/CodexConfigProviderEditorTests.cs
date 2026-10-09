using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Ported from the macOS app's <c>CodexConfigProviderEditorTests</c>. Same cases, same
/// expected results: any divergence is a porting bug.
/// </summary>
public class CodexConfigProviderEditorTests : IDisposable
{
    private readonly string _dir;
    private readonly string _config;
    private readonly string _backups;

    public CodexConfigProviderEditorTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), $"cfg-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_dir);
        _config = Path.Combine(_dir, "config.toml");
        _backups = Path.Combine(_dir, "backups");
    }

    public void Dispose()
    {
        if (Directory.Exists(_dir))
        {
            Directory.Delete(_dir, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    private void WriteConfig(string text) => File.WriteAllText(_config, text);

    private string ReadConfig() => File.ReadAllText(_config);

    private int BackupCount()
        => Directory.Exists(_backups) ? Directory.GetFiles(_backups).Length : 0;

    // ------------------------------------------------------------------ provider

    [Fact]
    public void SwitchingToARelayProviderRewritesOnlyTheTopLevelSelection()
    {
        WriteConfig("""
        model = "gpt-5.6-sol"
        model_provider = "openai"

        [plugins."computer-use@openai-bundled"]
        enabled = true

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """);

        var outcome = CodexConfigProviderEditor.SetSelectedProvider("custom", _config, _backups);

        Assert.Equal(ConfigEditKind.Updated, outcome.Kind);
        Assert.Equal("openai", outcome.Previous);
        Assert.Equal("custom", outcome.Current);

        var text = ReadConfig();
        // The switch changed, and everything else survived verbatim.
        Assert.Contains("model_provider = \"custom\"", text, StringComparison.Ordinal);
        Assert.Contains("model = \"gpt-5.6-sol\"", text, StringComparison.Ordinal);
        Assert.Contains("plugins.\"computer-use@openai-bundled\"", text, StringComparison.Ordinal);
        Assert.Contains("base_url = \"https://ai.apizn.com/v1\"", text, StringComparison.Ordinal);
        Assert.DoesNotContain("model_provider = \"openai\"", text, StringComparison.Ordinal);
    }

    [Fact]
    public void ClearingTheProviderRemovesTheTopLevelLineSoCodexUsesItsDefault()
    {
        // The section-local `model_provider` is the trap this case guards: clearing the
        // selection must not touch it, and a plain substring search cannot tell the two
        // apart — hence the assertion goes through the reader.
        WriteConfig("""
        model = "gpt-5.6-sol"
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        model_provider = "not-the-selection"
        """);

        var outcome = CodexConfigProviderEditor.SetSelectedProvider(null, _config, _backups);

        Assert.Equal(ConfigEditKind.Updated, outcome.Kind);
        Assert.Equal("custom", outcome.Previous);
        Assert.Null(outcome.Current);

        var text = ReadConfig();
        Assert.Null(CodexConfigReader.SelectedProviderFromToml(text));
        // The section-local key is untouched, and so is the rest of the file.
        Assert.Contains("model_provider = \"not-the-selection\"", text, StringComparison.Ordinal);
        Assert.Contains("base_url = \"https://ai.apizn.com/v1\"", text, StringComparison.Ordinal);
    }

    [Fact]
    public void AnAlreadyCorrectSelectionIsReportedAsUnchangedAndWritesNothing()
    {
        WriteConfig("""
        model_provider = "custom"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """);
        var before = ReadConfig();

        var outcome = CodexConfigProviderEditor.SetSelectedProvider("custom", _config, _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
        Assert.Equal(before, ReadConfig());
        Assert.Equal(0, BackupCount());
    }

    [Fact]
    public void AChangeIsBackedUpBeforeItIsWritten()
    {
        WriteConfig("""
        model_provider = "openai"
        """);

        CodexConfigProviderEditor.SetSelectedProvider("custom", _config, _backups);

        Assert.Equal(1, BackupCount());
        var backup = Directory.GetFiles(_backups)[0];
        Assert.Contains("model_provider = \"openai\"", File.ReadAllText(backup), StringComparison.Ordinal);
    }

    [Fact]
    public void AFileWithNoTopLevelSelectionGainsOneAheadOfTheFirstSection()
    {
        WriteConfig("""
        model = "gpt-5.6-sol"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """);

        CodexConfigProviderEditor.SetSelectedProvider("custom", _config, _backups);

        var text = ReadConfig();
        var provider = text.IndexOf("model_provider", StringComparison.Ordinal);
        var section = text.IndexOf("[model_providers", StringComparison.Ordinal);
        Assert.True(provider >= 0 && provider < section, "the key must land in the preamble");
    }

    [Fact]
    public void AMissingConfigIsLeftAloneRatherThanCreated()
    {
        var missing = Path.Combine(_dir, "nope.toml");

        var outcome = CodexConfigProviderEditor.SetSelectedProvider("custom", missing, _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
        Assert.False(File.Exists(missing));
    }

    // ------------------------------------------------------------------ section repair

    [Fact]
    public void AStrippedBaseUrlIsRestoredIntoItsOwnSection()
    {
        WriteConfig("""
        model_provider = "custom"

        [model_providers.custom]
        name = "OpenAI"
        """);

        var outcome = CodexConfigProviderEditor.SetProviderBaseUrl(
            "https://ai.apizn.com/v1", "custom", _config, _backups);

        Assert.Equal(ConfigEditKind.Updated, outcome.Kind);
        var text = ReadConfig();
        Assert.Contains("base_url = \"https://ai.apizn.com/v1\"", text, StringComparison.Ordinal);
        // The section keeps its other keys.
        Assert.Contains("name = \"OpenAI\"", text, StringComparison.Ordinal);
    }

    [Fact]
    public void AnAddressAlreadyPresentIsLeftAlone()
    {
        WriteConfig("""
        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """);

        var outcome = CodexConfigProviderEditor.SetProviderBaseUrl(
            "https://ai.apizn.com/v1", "custom", _config, _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
        Assert.Equal(0, BackupCount());
    }

    [Fact]
    public void RepairingIsRefusedWhenTheProviderSectionDoesNotExist()
    {
        WriteConfig("""
        model_provider = "custom"
        """);

        var outcome = CodexConfigProviderEditor.SetProviderBaseUrl(
            "https://ai.apizn.com/v1", "custom", _config, _backups);

        Assert.Equal(ConfigEditKind.Failed, outcome.Kind);
        Assert.Equal("provider_missing", outcome.Reason);
    }

    [Fact]
    public void ASubTableOfTheProviderDoesNotEndItsSection()
    {
        WriteConfig("""
        [model_providers.custom]
        base_url = "https://old.example/v1"

        [model_providers.custom.env]
        FOO = "bar"
        """);

        // The `base_url` is in the parent table, so it must be found and replaced.
        var outcome = CodexConfigProviderEditor.SetProviderBaseUrl(
            "https://new.example/v1", "custom", _config, _backups);

        Assert.Equal(ConfigEditKind.Updated, outcome.Kind);
        var text = ReadConfig();
        Assert.Contains("base_url = \"https://new.example/v1\"", text, StringComparison.Ordinal);
        Assert.Contains("FOO = \"bar\"", text, StringComparison.Ordinal);
    }

    [Fact]
    public void ADuplicateSectionIsWrittenToTheLastDeclarationBecauseCodexReadsThat()
    {
        WriteConfig("""
        [model_providers.custom]
        base_url = "https://first.example/v1"

        [model_providers.custom]
        base_url = "https://second.example/v1"
        """);

        CodexConfigProviderEditor.SetProviderBaseUrl(
            "https://third.example/v1", "custom", _config, _backups);

        var text = ReadConfig();
        // The effective (last) section is the one updated; the dead one is untouched.
        Assert.Contains("base_url = \"https://first.example/v1\"", text, StringComparison.Ordinal);
        Assert.Contains("base_url = \"https://third.example/v1\"", text, StringComparison.Ordinal);
        Assert.DoesNotContain("https://second.example/v1", text, StringComparison.Ordinal);
    }

    [Fact]
    public void CollapsingDuplicatesKeepsTheLastDeclaration()
    {
        WriteConfig("""
        [model_providers.custom]
        base_url = "https://first.example/v1"

        [model_providers.custom]
        base_url = "https://second.example/v1"
        """);

        var outcome = CodexConfigProviderEditor.CollapseDuplicateSections("custom", _config, _backups);

        Assert.Equal(ConfigEditKind.Updated, outcome.Kind);
        var text = ReadConfig();
        Assert.DoesNotContain("https://first.example/v1", text, StringComparison.Ordinal);
        Assert.Contains("https://second.example/v1", text, StringComparison.Ordinal);
        Assert.Equal(1, CountOccurrences(text, "[model_providers.custom]"));
    }

    [Fact]
    public void CollapsingIsANoOpWithASingleSection()
    {
        WriteConfig("""
        [model_providers.custom]
        base_url = "https://only.example/v1"
        """);

        var outcome = CodexConfigProviderEditor.CollapseDuplicateSections("custom", _config, _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
    }

    // ------------------------------------------------------------------ provider fields

    [Fact]
    public void WritingABooleanKeyProducesABareBooleanInTheFile()
    {
        WriteConfig("""
        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """);

        var outcome = CodexConfigProviderEditor.SetProviderField(
            "custom", "supports_websockets", "false", _config, _backups);

        Assert.Equal(ConfigEditKind.Updated, outcome.Kind);
        var text = ReadConfig();
        // The trap: `"false"` is a string, and Codex rejects the whole file.
        Assert.Contains("supports_websockets = false", text, StringComparison.Ordinal);
        Assert.DoesNotContain("supports_websockets = \"false\"", text, StringComparison.Ordinal);
    }

    [Fact]
    public void TogglingBackRestoresTheClaim()
    {
        WriteConfig("""
        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """);

        CodexConfigProviderEditor.SetProviderField("custom", "supports_websockets", "true", _config, _backups);
        Assert.Contains("supports_websockets = true", ReadConfig(), StringComparison.Ordinal);

        CodexConfigProviderEditor.SetProviderField("custom", "supports_websockets", "false", _config, _backups);
        var text = ReadConfig();
        Assert.Contains("supports_websockets = false", text, StringComparison.Ordinal);
        Assert.Equal(1, CountOccurrences(text, "supports_websockets"));
    }

    [Fact]
    public void AProviderFieldOnAMissingSectionIsRefused()
    {
        WriteConfig("""
        model_provider = "custom"
        """);

        var outcome = CodexConfigProviderEditor.SetProviderField(
            "custom", "wire_api", "responses", _config, _backups);

        Assert.Equal(ConfigEditKind.Failed, outcome.Kind);
        Assert.Equal("provider_missing", outcome.Reason);
    }

    [Fact]
    public void AnEmptyFieldValueIsIgnoredRatherThanWritten()
    {
        WriteConfig("""
        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """);

        var outcome = CodexConfigProviderEditor.SetProviderField(
            "custom", "wire_api", "   ", _config, _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
    }

    // ------------------------------------------------------------------ creating a section

    [Fact]
    public void ADeletedProviderSectionIsRecreated()
    {
        WriteConfig("""
        model_provider = "custom"
        """);

        var outcome = CodexConfigProviderEditor.EnsureProviderSection(
            "custom", "https://ai.apizn.com/v1", configPath: _config, backupDirectory: _backups);

        Assert.Equal(ConfigEditKind.Updated, outcome.Kind);
        var text = ReadConfig();
        Assert.Contains("[model_providers.custom]", text, StringComparison.Ordinal);
        Assert.Contains("base_url = \"https://ai.apizn.com/v1\"", text, StringComparison.Ordinal);
        Assert.Contains("wire_api = \"responses\"", text, StringComparison.Ordinal);
    }

    [Fact]
    public void AnExistingSectionIsLeftToTheFieldSetters()
    {
        WriteConfig("""
        [model_providers.custom]
        name = "custom"
        base_url = "https://ai.apizn.com/v1"
        """);

        var outcome = CodexConfigProviderEditor.EnsureProviderSection(
            "custom", "https://other.example/v1", configPath: _config, backupDirectory: _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
        Assert.Contains("https://ai.apizn.com/v1", ReadConfig(), StringComparison.Ordinal);
    }

    // ------------------------------------------------------------------ model keys

    [Fact]
    public void SwitchingToAnOfficialAccountClearsTheRelaysModelKeys()
    {
        WriteConfig("""
        model = "gpt-6-astra"
        model_catalog_json = "model-catalogs/relay-x.json"
        model_context_window = 1000000
        model_max_context_window = 1000000
        model_auto_compact_token_limit = 950000

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """);

        var outcome = CodexConfigProviderEditor.ClearRelayModelKeys(_config, _backups);

        Assert.Equal(ConfigEditKind.Updated, outcome.Kind);
        var text = ReadConfig();
        Assert.DoesNotContain("model_catalog_json", text, StringComparison.Ordinal);
        Assert.DoesNotContain("model_context_window", text, StringComparison.Ordinal);
        // The user's own model choice is not a relay fact and stays.
        Assert.Contains("model = \"gpt-6-astra\"", text, StringComparison.Ordinal);
    }

    [Fact]
    public void AProfilesOwnModelKeysAreNotMistakenForThePreambles()
    {
        WriteConfig("""
        model = "gpt-6-astra"

        [profiles.work]
        model_context_window = 1000000
        """);

        // Nothing in the preamble to clear, so nothing changes.
        var outcome = CodexConfigProviderEditor.ClearRelayModelKeys(_config, _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
        Assert.Contains("model_context_window = 1000000", ReadConfig(), StringComparison.Ordinal);
    }

    [Fact]
    public void ClearingIsANoOpWhenNoRelayKeysArePresent()
    {
        WriteConfig("""
        model = "gpt-6-astra"
        """);

        var outcome = CodexConfigProviderEditor.ClearRelayModelKeys(_config, _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
        Assert.Equal(0, BackupCount());
    }

    [Fact]
    public void SwitchingToARelayAccountDropsTheUnloadableCatalogPath()
    {
        WriteConfig("""
        model_provider = "custom"
        model_catalog_json = "model-catalogs/relay-x.json"
        model_context_window = 1000000

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """);

        var outcome = CodexConfigProviderEditor.ClearInertModelCatalog(_config, _backups);

        Assert.Equal(ConfigEditKind.Updated, outcome.Kind);
        var text = ReadConfig();
        // The relative path could never load, so it goes.
        Assert.DoesNotContain("model_catalog_json", text, StringComparison.Ordinal);
        // The context window is a separate decision and is not touched here.
        Assert.Contains("model_context_window = 1000000", text, StringComparison.Ordinal);
    }

    [Fact]
    public void AnAbsoluteCatalogPathIsADeliberateChoiceAndStays()
    {
        var absolute = Path.Combine(_dir, "my-catalog.json");
        WriteConfig($"""
        model_catalog_json = "{absolute.Replace("\\", "\\\\", StringComparison.Ordinal)}"
        """);

        var outcome = CodexConfigProviderEditor.ClearInertModelCatalog(_config, _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
    }

    /// <summary>
    /// A Windows drive-letter path is absolute. Treating it as inert would delete a real
    /// choice the user made.
    /// </summary>
    [Fact]
    public void AWindowsDrivePathCatalogIsNotTreatedAsInert()
    {
        WriteConfig("""
        model_catalog_json = "C:\\Users\\me\\.codex\\models.json"
        """);

        var outcome = CodexConfigProviderEditor.ClearInertModelCatalog(_config, _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
    }

    // ------------------------------------------------------------------ context window

    [Fact]
    public void TheStandardWindowIs400kAndCompactsAt90Percent()
    {
        var standard = CodexConfigProviderEditor.ContextWindow.Standard;
        Assert.Equal(400_000, standard.Window);
        Assert.Equal(0.9, standard.CompactFraction);
        Assert.Equal(360_000, standard.CompactLimit);
    }

    [Fact]
    public void AStaleSwitcherValueIsRewrittenNotAppended()
    {
        WriteConfig("""
        model = "gpt-6-astra"
        model_context_window = 618000
        model_max_context_window = 1000000
        model_auto_compact_token_limit = 950000
        """);

        var outcome = CodexConfigProviderEditor.SetContextWindow(
            CodexConfigProviderEditor.ContextWindow.Standard, _config, _backups);

        Assert.Equal(ConfigEditKind.Updated, outcome.Kind);
        var text = ReadConfig();
        Assert.Contains("model_context_window = 400000", text, StringComparison.Ordinal);
        Assert.Contains("model_auto_compact_token_limit = 360000", text, StringComparison.Ordinal);
        Assert.DoesNotContain("618000", text, StringComparison.Ordinal);
        Assert.Equal(1, CountOccurrences(text, "model_context_window"));
    }

    [Fact]
    public void KeysAreAddedWhenTheFileHasNone()
    {
        WriteConfig("""
        model = "gpt-6-astra"

        [model_providers.custom]
        base_url = "https://ai.apizn.com/v1"
        """);

        CodexConfigProviderEditor.SetContextWindow(
            CodexConfigProviderEditor.ContextWindow.Standard, _config, _backups);

        var text = ReadConfig();
        Assert.Contains("model_context_window = 400000", text, StringComparison.Ordinal);
        // Added to the preamble, not inside the provider section.
        var key = text.IndexOf("model_context_window", StringComparison.Ordinal);
        var section = text.IndexOf("[model_providers", StringComparison.Ordinal);
        Assert.True(key < section, "window keys belong to the preamble");
    }

    [Fact]
    public void RunningTwiceChangesNothingTheSecondTime()
    {
        WriteConfig("""
        model = "gpt-6-astra"
        """);

        CodexConfigProviderEditor.SetContextWindow(
            CodexConfigProviderEditor.ContextWindow.Standard, _config, _backups);
        var afterFirst = ReadConfig();
        var backupsAfterFirst = BackupCount();

        var outcome = CodexConfigProviderEditor.SetContextWindow(
            CodexConfigProviderEditor.ContextWindow.Standard, _config, _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
        Assert.Equal(afterFirst, ReadConfig());
        Assert.Equal(backupsAfterFirst, BackupCount());
    }

    [Fact]
    public void APreExistingDuplicateCollapsesToOneKey()
    {
        WriteConfig("""
        model_context_window = 618000
        model_context_window = 1000000
        """);

        CodexConfigProviderEditor.SetContextWindow(
            CodexConfigProviderEditor.ContextWindow.Standard, _config, _backups);

        var text = ReadConfig();
        Assert.Equal(1, CountOccurrences(text, "model_context_window"));
        Assert.Contains("model_context_window = 400000", text, StringComparison.Ordinal);
    }

    [Fact]
    public void AProfilesOwnContextKeysAreNotTouched()
    {
        WriteConfig("""
        model = "gpt-6-astra"

        [profiles.work]
        model_context_window = 1000000
        """);

        CodexConfigProviderEditor.SetContextWindow(
            CodexConfigProviderEditor.ContextWindow.Standard, _config, _backups);

        var text = ReadConfig();
        // The profile's own value survives; the preamble gains this tool's.
        Assert.Contains("model_context_window = 1000000", text, StringComparison.Ordinal);
        Assert.Contains("model_context_window = 400000", text, StringComparison.Ordinal);
    }

    [Fact]
    public void AMissingConfigIsNotCreatedByTheWindowWriter()
    {
        var missing = Path.Combine(_dir, "absent.toml");

        var outcome = CodexConfigProviderEditor.SetContextWindow(
            CodexConfigProviderEditor.ContextWindow.Standard, missing, _backups);

        Assert.Equal(ConfigEditKind.Unchanged, outcome.Kind);
        Assert.False(File.Exists(missing));
    }

    // ------------------------------------------------------------------ TOML value formatting

    [Theory]
    [InlineData("true", "true")]
    [InlineData("false", "false")]
    [InlineData("400000", "400000")]
    [InlineData("-5", "-5")]
    [InlineData("0.9", "0.9")]
    public void BooleansAndNumbersAreWrittenBare(string input, string expected)
        => Assert.Equal(expected, CodexConfigProviderEditor.TomlValue(input));

    [Theory]
    [InlineData("custom")]
    [InlineData("responses")]
    [InlineData("https://ai.apizn.com/v1")]
    [InlineData("")]
    public void EverythingElseIsQuoted(string input)
    {
        var result = CodexConfigProviderEditor.TomlValue(input);
        Assert.StartsWith("\"", result, StringComparison.Ordinal);
        Assert.EndsWith("\"", result, StringComparison.Ordinal);
    }

    [Fact]
    public void QuotesAndBackslashesInAValueAreEscaped()
    {
        Assert.Equal("\"a\\\"b\"", CodexConfigProviderEditor.TomlValue("a\"b"));
        Assert.Equal("\"a\\\\b\"", CodexConfigProviderEditor.TomlValue("a\\b"));
    }

    // ------------------------------------------------------------------ atomic write

    [Fact]
    public void AtomicWriteLeavesNoTemporaryFilesBehind()
    {
        CodexConfigProviderEditor.AtomicWrite("hello", _config);

        Assert.Equal("hello", ReadConfig());
        Assert.Single(Directory.GetFiles(_dir, "*.toml"));
    }

    [Fact]
    public void AtomicWriteReplacesAnExistingFile()
    {
        WriteConfig("old");
        CodexConfigProviderEditor.AtomicWrite("new", _config);

        Assert.Equal("new", ReadConfig());
    }

    /// <summary>Round-trips through the reader, proving writer and reader agree.</summary>
    [Fact]
    public void AWrittenProviderIsReadBackByTheReader()
    {
        WriteConfig("model = \"gpt-6-astra\"\n");

        CodexConfigProviderEditor.EnsureProviderSection(
            "custom", "https://ai.apizn.com/v1", configPath: _config, backupDirectory: _backups);
        CodexConfigProviderEditor.SetSelectedProvider("custom", _config, _backups);

        Assert.Equal("custom", CodexConfigReader.SelectedProvider(_config));
        Assert.Equal("https://ai.apizn.com/v1",
            CodexConfigReader.ProviderBaseUrls(_config)["custom"]);
    }

    private static int CountOccurrences(string text, string needle)
        => text.Split(needle, StringSplitOptions.None).Length - 1;
}
