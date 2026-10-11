using CodexRunway.Core;
using Xunit;

namespace CodexRunway.Core.Tests;

/// <summary>
/// Config edits must not change a file's line endings.
/// </summary>
/// <remarks>
/// Codex's config on Windows may use CRLF. Splitting on <c>\n</c> leaves the <c>\r</c>
/// attached to each line, so an edit used to leave the touched lines with one ending and
/// the rest with another — a mixed file. This is the kind of damage that is invisible in a
/// diff and only shows up as a config Codex misreads.
/// </remarks>
public class LineEndingTests : IDisposable
{
    private readonly string _dir;
    private readonly string _config;
    private readonly string _backups;

    public LineEndingTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), $"eol-{Guid.NewGuid():N}");
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

    private const string CrLfBody =
        "model_provider = \"custom\"\r\n"
        + "model = \"gpt-6-astra\"\r\n"
        + "\r\n"
        + "[model_providers.custom]\r\n"
        + "base_url = \"https://old.example/v1\"\r\n"
        + "name = \"custom\"\r\n";

    private const string LfBody =
        "model_provider = \"custom\"\n"
        + "model = \"gpt-6-astra\"\n"
        + "\n"
        + "[model_providers.custom]\n"
        + "base_url = \"https://old.example/v1\"\n"
        + "name = \"custom\"\n";

    private static int Count(string text, string needle)
    {
        var count = 0;
        var index = 0;
        while ((index = text.IndexOf(needle, index, StringComparison.Ordinal)) >= 0)
        {
            count++;
            index += needle.Length;
        }

        return count;
    }

    private static int BareLineFeeds(string text) => Count(text, "\n") - Count(text, "\r\n");

    private void AssertUniform(string text, bool expectCrLf)
    {
        var crlf = Count(text, "\r\n");
        var bare = BareLineFeeds(text);

        if (expectCrLf)
        {
            Assert.True(crlf > 0, "expected CRLF endings to be preserved");
            Assert.Equal(0, bare);
        }
        else
        {
            Assert.Equal(0, crlf);
            Assert.True(bare > 0);
        }
    }

    [Fact]
    public void EditingAValueKeepsCrLfThroughout()
    {
        File.WriteAllText(_config, CrLfBody);

        CodexConfigProviderEditor.SetProviderBaseUrl(
            "https://new.example/v1", "custom", _config, _backups);

        AssertUniform(File.ReadAllText(_config), expectCrLf: true);
    }

    [Fact]
    public void WritingAPreambleKeyKeepsCrLfThroughout()
    {
        File.WriteAllText(_config, CrLfBody);

        CodexConfigProviderEditor.SetContextWindow(
            CodexConfigProviderEditor.ContextWindow.Standard, _config, _backups);

        AssertUniform(File.ReadAllText(_config), expectCrLf: true);
    }

    /// <summary>
    /// Switching the selected provider rewrites the top-level line while keeping CRLF.
    /// </summary>
    /// <remarks>
    /// The target provider is <em>different</em> from the one the fixture already selects, and the
    /// edit is asserted to have happened. Selecting the already-current provider returns
    /// <c>Unchanged</c> and writes nothing, so an earlier version of this test asserted the line
    /// endings of a file the editor had never touched — it could not fail, whatever the writer did.
    /// </remarks>
    [Fact]
    public void SwitchingTheProviderKeepsCrLfThroughout()
    {
        File.WriteAllText(_config, CrLfBody);

        var outcome = CodexConfigProviderEditor.SetSelectedProvider("other", _config, _backups);

        Assert.Equal(ConfigEditKind.Updated, outcome.Kind);
        var text = File.ReadAllText(_config);
        Assert.Contains("model_provider = \"other\"", text, StringComparison.Ordinal);
        AssertUniform(text, expectCrLf: true);
    }

    [Fact]
    public void CreatingASectionKeepsCrLfThroughout()
    {
        File.WriteAllText(_config, "model_provider = \"custom\"\r\n");

        CodexConfigProviderEditor.EnsureProviderSection(
            "custom", "https://new.example/v1", configPath: _config, backupDirectory: _backups);

        AssertUniform(File.ReadAllText(_config), expectCrLf: true);
    }

    [Fact]
    public void CollapsingDuplicatesKeepsCrLfThroughout()
    {
        File.WriteAllText(_config,
            "[model_providers.custom]\r\nbase_url = \"https://a.example/v1\"\r\n"
            + "\r\n"
            + "[model_providers.custom]\r\nbase_url = \"https://b.example/v1\"\r\n");

        CodexConfigProviderEditor.CollapseDuplicateSections("custom", _config, _backups);

        AssertUniform(File.ReadAllText(_config), expectCrLf: true);
    }

    /// <summary>
    /// The other direction matters just as much: an LF file must not acquire CRLF, or the
    /// macOS build would see every line change on a file Windows merely touched.
    /// </summary>
    [Fact]
    public void EditingAnLfFileDoesNotIntroduceCrLf()
    {
        File.WriteAllText(_config, LfBody);

        CodexConfigProviderEditor.SetProviderBaseUrl(
            "https://new.example/v1", "custom", _config, _backups);
        CodexConfigProviderEditor.SetContextWindow(
            CodexConfigProviderEditor.ContextWindow.Standard, _config, _backups);

        AssertUniform(File.ReadAllText(_config), expectCrLf: false);
    }

    [Fact]
    public void ACrLfFileIsStillReadableByTheReader()
    {
        File.WriteAllText(_config, CrLfBody);

        Assert.Equal("custom", CodexConfigReader.SelectedProvider(_config));
        Assert.Equal("https://old.example/v1",
            CodexConfigReader.ProviderBaseUrls(_config)["custom"]);
    }
}
