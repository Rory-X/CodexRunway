using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using CodexRunway.Desktop;
using CodexRunway.Presentation;

namespace CodexRunway.Desktop.Views;

/// <summary>
/// The account panel.
/// </summary>
/// <remarks>
/// Thin by design: which accounts appear, in what order, and how each is toned are decided by
/// <c>CodexRunway.Presentation</c>, which is covered by unit tests. This class moves that data
/// onto controls.
/// </remarks>
public partial class MainWindow : Window
{
    private readonly PanelService _service;
    private PanelState _state = PanelState.Idle;

    /// <summary>Parameterless constructor for the XAML previewer.</summary>
    public MainWindow()
        : this(null!)
    {
    }

    public MainWindow(PanelService service)
    {
        _service = service;
        InitializeComponent();

        RefreshButton.Click += (_, _) => Refresh();
        QuitButton.Click += (_, _) =>
            (Application.Current?.ApplicationLifetime
                as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)
                ?.Shutdown();

        KeyDown += OnKeyDown;

        if (service is not null)
        {
            Refresh();
        }
    }

    /// <summary>Reloads and renders.</summary>
    public void Refresh()
    {
        _state = _service.Load();
        Apply(_state);
    }

    /// <summary>Renders a state, or a placeholder message when there is nothing to build from.</summary>
    private void Apply(PanelState state)
    {
        var hasRows = state.Accounts.Count > 0;

        AccountList.ItemsSource = state.Accounts;
        AccountsHeader.IsVisible = hasRows;
        AccountList.IsVisible = hasRows;

        // Each state gets its own wording, because "no accounts", "could not read them" and
        // "names unavailable" call for different user actions even though they look alike.
        var (message, tone) = Describe(state);
        StatusText.Text = message;
        StatusPanel.IsVisible = message.Length > 0;
        StatusText.Foreground = tone;

        EmptyText.IsVisible = state.Status == PanelStatus.Empty;
        EmptyText.Text = "No accounts yet. Add one and it will appear here, with its quota.";

        CountText.Text = hasRows ? $"{state.Accounts.Count} accounts" : string.Empty;
        FooterText.Text = state.RefreshedAt is { } at
            ? $"Updated {at.LocalDateTime:HH:mm:ss}"
            : string.Empty;
    }

    private (string Message, IBrush Tone) Describe(PanelState state)
    {
        var secondary = FindBrush("TextSecondaryBrush");
        var problem = FindBrush("ProblemBrush");

        return state.Status switch
        {
            PanelStatus.Loading => ("Reading accounts…", secondary),
            PanelStatus.Failed => (MessageFor(state.Problem), problem),
            _ when state.StatusMessageCode is not null => (MessageFor(state.StatusMessageCode), secondary),
            _ => (string.Empty, secondary),
        };
    }

    /// <summary>
    /// Turns a status code into something a person can act on.
    /// </summary>
    /// <remarks>
    /// Codes rather than sentences travel through the presentation layer, so the wording lives
    /// here — the one place a real localisation table would be consulted.
    /// </remarks>
    private static string MessageFor(string? code) => code switch
    {
        "accounts_unreadable" =>
            "None of your accounts could be read. The files may be corrupt or locked by another program.",
        "accounts_partially_unreadable" =>
            "Some accounts could not be read and are not listed.",
        "index_unavailable" =>
            "Account names are unavailable — the index could not be read. Accounts are still listed.",
        _ => code ?? string.Empty,
    };

    private IBrush FindBrush(string key)
        => this.TryFindResource(key, out var value) && value is IBrush brush
            ? brush
            : Brushes.Gray;

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Close();
        }
        else if (e.Key == Key.F5)
        {
            Refresh();
        }
    }
}
