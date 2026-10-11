using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using CodexRunway.Presentation;

namespace CodexRunway.App;

/// <summary>
/// The account panel.
/// </summary>
/// <remarks>
/// Thin by design. Which accounts appear, in what order, how each row is toned and what each
/// quota line says are all decided by <c>CodexRunway.Presentation</c>, which is
/// platform-neutral and covered by unit tests. This class moves that data onto controls, so the
/// two platforms cannot disagree about what "low quota" or "needs sign-in" means.
/// </remarks>
public partial class MainWindow : Window
{
    private readonly PanelService? _service;
    private PanelState _state = PanelState.Idle;

    /// <summary>Parameterless constructor for the XAML designer.</summary>
    public MainWindow()
        : this(null)
    {
    }

    public MainWindow(PanelService? service)
    {
        _service = service;
        InitializeComponent();

        if (service is not null)
        {
            Refresh();
        }
    }

    /// <summary>Reloads and renders.</summary>
    public void Refresh()
    {
        if (_service is null)
        {
            return;
        }

        _state = _service.Load();
        Apply(_state);
    }

    private void Apply(PanelState state)
    {
        var hasRows = state.Accounts.Count > 0;

        AccountList.ItemsSource = state.Accounts;
        AccountsHeader.Visibility = hasRows ? Visibility.Visible : Visibility.Collapsed;

        var (message, tone) = Describe(state);
        StatusText.Text = message;
        StatusText.Foreground = FindBrush(tone);
        StatusPanel.Visibility = message.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

        EmptyText.Visibility = state.Status == PanelStatus.Empty ? Visibility.Visible : Visibility.Collapsed;
        EmptyText.Text = "还没有账号。添加后会显示在这里，并带上它的配额。";

        CountText.Text = hasRows ? $"{state.Accounts.Count} 个账号" : string.Empty;
        FooterText.Text = state.RefreshedAt is { } at ? $"更新于 {at.LocalDateTime:HH:mm:ss}" : string.Empty;
    }

    /// <summary>
    /// Wording and tone for the status strip.
    /// </summary>
    /// <remarks>
    /// Codes travel through the presentation layer, so the sentences live here — the single
    /// place a localisation table would be consulted. Each state gets its own message, because
    /// "no accounts", "could not read them" and "names unavailable" call for different actions
    /// even though they look alike on screen.
    /// </remarks>
    private static (string Message, string BrushKey) Describe(PanelState state) => state.Status switch
    {
        PanelStatus.Loading => ("正在读取账号…", "TextSecondaryBrush"),
        PanelStatus.Failed => (ProblemMessage(state.Problem), "HealthRedBrush"),
        _ when state.StatusMessageCode is not null => (ProblemMessage(state.StatusMessageCode), "TextSecondaryBrush"),
        _ => (string.Empty, "TextSecondaryBrush"),
    };

    private static string ProblemMessage(string? code) => code switch
    {
        "accounts_unreadable" => "无法读取任何账号。文件可能已损坏，或被其他程序占用。",
        "accounts_partially_unreadable" => "部分账号无法读取，未在列表中显示。",
        "index_unavailable" => "账号名称不可用——索引读取失败。账号仍会列出。",
        _ => code ?? string.Empty,
    };

    private Brush FindBrush(string key)
        => TryFindResource(key) as Brush ?? new SolidColorBrush(Colors.Gray);

    /// <summary>
    /// Switches to the account on the row whose button was pressed.
    /// </summary>
    /// <remarks>
    /// The id is read from the button's Tag rather than from a selection, because the panel has
    /// no selection concept: a switch is a click on one row, not a mode. A refusal is reported
    /// rather than swallowed, since "nothing appeared to happen" is the least useful outcome for
    /// an operation that writes two files.
    /// </remarks>
    private void OnSwitchClicked(object sender, RoutedEventArgs e)
    {
        if (_service is null || sender is not FrameworkElement { Tag: string accountId })
        {
            return;
        }

        var row = _state.Accounts.FirstOrDefault(a => a.Id == accountId);
        if (row is null)
        {
            return;
        }

        var result = _service.SwitchTo(row);
        if (result.Succeeded)
        {
            Refresh();
            return;
        }

        StatusText.Text = SwitchFailureMessage(result.Reason);
        StatusText.Foreground = FindBrush("HealthRedBrush");
        StatusPanel.Visibility = Visibility.Visible;
    }

    /// <summary>
    /// Wording for a refused switch.
    /// </summary>
    /// <remarks>
    /// Each reason names something the user can act on. A generic "switch failed" would leave
    /// them guessing between a corrupt credential and a config file another program is holding.
    /// </remarks>
    private static string SwitchFailureMessage(string? reason) => reason switch
    {
        "account_credential_missing" => "该账号的凭据文件已不存在。",
        "account_credential_invalid" => "该账号的凭据文件无法解析。",
        "account_credential_unreadable" => "该账号的凭据文件无法读取，可能被其他程序占用。",
        "account_credential_unusable" => "该账号的凭据不可用，请重新登录。",
        "config_unreadable" => "config.toml 无法读取或写入，切号未执行。",
        "config_write_failed" => "config.toml 写入失败，切号未执行。",
        "config_backup_failed" => "备份 config.toml 失败，切号未执行。",
        "credential_install_failed" => "写入 auth.json 失败，切号未完成。",
        _ => reason ?? "切号失败。",
    };

    /// <summary>Moves an account one position up in the user's order.</summary>
    private void OnMoveUpClicked(object sender, RoutedEventArgs e) => MoveRow(sender, -1);

    /// <summary>Moves an account one position down in the user's order.</summary>
    private void OnMoveDownClicked(object sender, RoutedEventArgs e) => MoveRow(sender, +1);

    private void MoveRow(object sender, int delta)
    {
        if (_service is null || sender is not FrameworkElement { Tag: string accountId })
        {
            return;
        }

        // Reload either way: on success the order changed, and on failure the stored order is the
        // truth, so showing the optimistic arrangement would be a lie.
        _service.MoveAccount(accountId, delta);
        Refresh();
    }

    /// <summary>
    /// Removes an account, after confirming.
    /// </summary>
    /// <remarks>
    /// Confirmed because the credential is the only copy of a login the user cannot re-derive —
    /// they would have to sign in again — and because the panel is a single click away from
    /// actions, which makes an unconfirmed destructive button easy to hit by accident. The
    /// dialog also states plainly that the credential is removed, rather than asking a vague
    /// "are you sure".
    /// </remarks>
    private void OnDeleteClicked(object sender, RoutedEventArgs e)
    {
        if (_service is null || sender is not FrameworkElement { Tag: string accountId })
        {
            return;
        }

        var row = _state.Accounts.FirstOrDefault(a => a.Id == accountId);
        var name = row?.Title ?? accountId;

        var confirmed = MessageBox.Show(
            $"确定要移除「{name}」吗？\n\n这会删除该账号保存的登录凭据，之后需要重新登录才能恢复。",
            "移除账号",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning,
            MessageBoxResult.Cancel);

        if (confirmed != MessageBoxResult.OK)
        {
            return;
        }

        var removed = _service.RemoveAccount(accountId, deleteCredential: true);
        Refresh();

        if (!removed)
        {
            StatusText.Text = "移除未完成：账号索引可能被其他程序修改过，请重试。";
            StatusText.Foreground = FindBrush("HealthRedBrush");
            StatusPanel.Visibility = Visibility.Visible;
        }
    }

    private void OnRefreshClicked(object sender, RoutedEventArgs e) => Refresh();

    private void OnMinimizeClicked(object sender, RoutedEventArgs e)
        => WindowState = WindowState.Minimized;

    private void OnCloseClicked(object sender, RoutedEventArgs e) => Close();

    /// <summary>
    /// Lets the window be moved by its header.
    /// </summary>
    /// <remarks>
    /// The window has no title bar, so this restores the drag a chrome-less window otherwise
    /// loses. Double-clicking maximises, which is the convention on Windows.
    /// </remarks>
    private void OnHeaderDrag(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            WindowState = WindowState == WindowState.Maximized
                ? WindowState.Normal
                : WindowState.Maximized;
            return;
        }

        if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);

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
