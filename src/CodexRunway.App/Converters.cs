using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using CodexRunway.Presentation;

namespace CodexRunway.App;

/// <summary>
/// Maps a quota health value onto the brush that represents it.
/// </summary>
/// <remarks>
/// The thresholds live in <see cref="QuotaWindowView.HealthFor"/> so both platforms agree on
/// what "low" means; this converter only chooses a colour, which is the part WPF cannot do
/// from a plain binding.
/// </remarks>
public sealed class HealthToBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var key = value switch
        {
            QuotaHealth.Green => "HealthGreenBrush",
            QuotaHealth.Yellow => "HealthYellowBrush",
            QuotaHealth.Red => "HealthRedBrush",
            _ => "TextSecondaryBrush",
        };

        return Application.Current?.TryFindResource(key) as Brush
            ?? new SolidColorBrush(Colors.Gray);
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>
/// Resolves a resource key produced by the presentation layer into a brush.
/// </summary>
/// <remarks>
/// Used where the choice of colour is a decision rather than a lookup: which of two quota
/// windows matters, whether a balance is positive. The rule lives in
/// <c>CodexRunway.Presentation</c> so both platforms agree; the key travels to the view because
/// only the view knows the resource dictionary.
/// </remarks>
public sealed class HealthKeyToBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var key = value as string;
        if (string.IsNullOrEmpty(key))
        {
            key = "TextSecondaryBrush";
        }

        return Application.Current?.TryFindResource(key) as Brush
            ?? new SolidColorBrush(Colors.Gray);
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>
/// Collapses an element when its bound value is false, null, an empty string or an empty
/// collection.
/// </summary>
/// <remarks>
/// One converter rather than WPF's bool-only one, because a binding target here may be a
/// string, a list or a flag, and having a single rule means a view cannot accidentally leave an
/// empty row visible.
/// </remarks>
public sealed class NotEmptyToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var hasContent = value switch
        {
            null => false,
            bool flag => flag,
            string text => !string.IsNullOrWhiteSpace(text),
            System.Collections.ICollection collection => collection.Count > 0,
            System.Collections.IEnumerable items => items.GetEnumerator().MoveNext(),
            _ => true,
        };

        return hasContent ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>
/// Renders a plan name as a short badge label.
/// </summary>
/// <remarks>
/// The index stores lower-case plan ids, and the macOS build shows them capitalised on badges.
/// Deriving it here keeps the stored value untouched, so a badge never round-trips a
/// prettified string back into the shared file.
/// </remarks>
public sealed class PlanBadgeConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not string plan || string.IsNullOrWhiteSpace(plan))
        {
            return string.Empty;
        }

        return plan.Length <= 1 ? plan.ToUpperInvariant() : char.ToUpperInvariant(plan[0]) + plan[1..];
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
