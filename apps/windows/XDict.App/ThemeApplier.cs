// The reader's theme choice, applied to a window's root: "system" follows Windows.
using Microsoft.UI.Xaml;

namespace XDict.App;

internal static class ThemeApplier
{
    /// <summary>The theme actually in force: the reader's choice, or what Windows is showing for "system".</summary>
    public static string Effective(string theme) => theme switch
    {
        "light" or "dark" => theme,
        _ => Application.Current.RequestedTheme == ApplicationTheme.Dark ? "dark" : "light",
    };

    public static void Apply(FrameworkElement? root, string theme)
    {
        if (root is null) return;
        root.RequestedTheme = theme switch
        {
            "light" => ElementTheme.Light,
            "dark" => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
    }
}
