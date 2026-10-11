using System.Windows;
using System.Windows.Controls;
using System.Windows.Forms;
using System.Windows.Input;
using CodexRunway.Presentation;

namespace CodexRunway.App;

/// <summary>
/// The tray flyout: an account list with a status line.
/// </summary>
/// <remarks>
/// Deliberately thin. Every decision about content — which accounts, what order, how a value
/// reads, what colour a row is — is made by <see cref="PanelState"/> and
/// <see cref="AccountRow"/>, which are platform-neutral and unit-tested. This class only
/// moves that data onto controls and raises intent events back to
/// <see cref="TrayHost"/>.
/// </remarks>
public partial class FlyoutWindow : Window
{
    public FlyoutWindow()
    {
        InitializeComponent();
    }

    /// <summary>Raised when the user asks for fresh data.</summary>
    public event EventHandler? RefreshRequested;

    /// <summary>Raised with an account id when the user asks to switch to it.</summary>
    public event EventHandler<string>? SwitchRequested;

    /// <summary>Renders a state onto the controls.</summary>
    public void Apply(PanelState state)
    {
        AccountList.ItemsSource = state.Accounts;

        var showAccounts = state.Status is PanelStatus.Ready or PanelStatus.Failed;
        AccountsHeader.Visibility = showAccounts ? Visibility.Visible : Visibility.Collapsed;
        AccountList.Visibility = showAccounts ? Visibility.Visible : Visibility.Collapsed;

        // Four distinct messages, because "no accounts", "still loading" and "could not read
        // your accounts" call for different user actions even though they look alike.
        var (message, show) = state.Status switch
        {
            PanelStatus.Loading => ("Reading accounts…", true),
            PanelStatus.Empty => ("No accounts yet. Add one in the settings window.", true),
            PanelStatus.Failed => (DescribeProblem(state.Problem), true),
            _ when state.StatusMessageCode is not null => (DescribeProblem(state.StatusMessageCode), true),
            _ => (string.Empty, false),
        };

        StatusText.Text = message;
        StatusText.Visibility = show ? Visibility.Visible : Visibility.Collapsed;

        EmptyText.Visibility = state.Status == PanelStatus.Empty ? Visibility.Visible : Visibility.Collapsed;
        if (state.Status == PanelStatus.Empty)
        {
            EmptyText.Text = "Once an account is added it appears here, with its quota.";
        }

        FooterText.Text = state.RefreshedAt is { } at
            ? $"Updated {at.LocalDateTime:HH:mm:ss}"
            : string.Empty;
    }

    /// <summary>
    /// Turns a status code into something a person can act on.
    /// </summary>
    /// <remarks>
    /// Codes rather than sentences travel through the presentation layer, so this is the one
    /// place the wording lives — the point at which a real localisation table would be
    /// consulted.
    /// </remarks>
    private static string DescribeProblem(string? code) => code switch
    {
        "accounts_unreadable" => "None of your accounts could be read. They may be corrupt, or the files may be locked by another program.",
        "accounts_partially_unreadable" => "Some accounts could not be read and are not listed.",
        _ => code ?? string.Empty,
    };

    /// <summary>
    /// Positions the flyout next to the notification area.
    /// </summary>
    /// <remarks>
    /// The tray icon gives no coordinates, so the cursor position is the only anchor
    /// available; the window is then clamped to the working area of whichever screen the
    /// cursor is on, so it never opens off-screen on a multi-monitor setup.
    /// </remarks>
    public void ShowNear(NotifyIcon icon)
    {
        var cursor = System.Windows.Forms.Cursor.Position;
        var screen = Screen.FromPoint(cursor);
        var area = screen.WorkingArea;

        Left = Math.Clamp(
            cursor.X - (Width / 2),
            area.Left + 8,
            area.Right - Width - 8);

        // Bottom-right by convention: the notification area lives there, so the panel grows
        // upward from it rather than covering it.
        Top = area.Bottom - ActualHeight - 12;

        Show();
        Activate();
    }

    /// <summary>
    /// Raises the switch intent for the row whose button was pressed.
    /// </summary>
    /// <remarks>
    /// The id comes from the bound row rather than from a selection, because the panel has no
    /// selection concept — a switch is a click on one row, not a mode.
    /// </remarks>
    private void OnSwitchClicked(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: AccountRow row })
        {
            SwitchRequested?.Invoke(this, row.Id);
        }
    }

    private void OnRefreshClicked(object sender, RoutedEventArgs e)
        => RefreshRequested?.Invoke(this, EventArgs.Empty);

    private void OnQuitClicked(object sender, RoutedEventArgs e)
    {
        System.Windows.Application.Current.Shutdown();
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        // Clicking anywhere else dismisses the flyout, matching tray behaviour on both
        // platforms. Cancel in TrayHost's Closing handler is what makes this a hide.
        Hide();
    }

    private void OnKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Hide();
        }
    }
}
