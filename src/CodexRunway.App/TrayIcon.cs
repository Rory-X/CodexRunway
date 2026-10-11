using System.Drawing;
using System.Drawing.Drawing2D;

namespace CodexRunway.App;

/// <summary>
/// Draws the notification-area icon.
/// </summary>
/// <remarks>
/// Generated rather than shipped as a file: there is then no binary asset to keep in step with
/// the accent colour, and one definition renders at whatever size the notification area asks
/// for. The shape is a rounded accent tile with a runway chevron, legible at 16 pixels, which
/// is what Windows actually draws.
/// </remarks>
internal static class TrayIcon
{
    public static Icon Create(Color accent)
    {
        using var bitmap = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);

            using var fill = new SolidBrush(accent);
            g.FillEllipse(fill, 2, 2, 28, 28);

            using var pen = new Pen(Color.White, 2.6f)
            {
                StartCap = LineCap.Round,
                EndCap = LineCap.Round,
                LineJoin = LineJoin.Round,
            };
            g.DrawLine(pen, 10.5f, 20.5f, 16f, 11f);
            g.DrawLine(pen, 16f, 11f, 21.5f, 20.5f);
        }

        // Icon.FromHandle does not take ownership, so the clone keeps the icon alive after the
        // bitmap is disposed.
        var handle = bitmap.GetHicon();
        using var fromHandle = Icon.FromHandle(handle);
        return (Icon)fromHandle.Clone();
    }
}
