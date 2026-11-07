// The reader's theme choice, applied to a window's root: "system" follows Windows.
using Microsoft.UI.Xaml;
using XDict.Models;

namespace XDict.App;

internal static class ThemeApplier
{
    /// <summary>The theme actually in force: the reader's choice, or what Windows is showing for "system".</summary>
    public static string Effective(string theme) => theme switch
    {
        "light" or "dark" => theme,
        _ => Application.Current.RequestedTheme == ApplicationTheme.Dark ? "dark" : "light",
    };

    /// <summary>Raised when the reader changes the theme, for every window already open to follow.</summary>
    public static event Action<string>? Changed;

    /// <summary>Applies the choice to the main root and tells every open window to do the same.</summary>
    public static void Publish(string theme)
    {
        Apply(App.CurrentRoot, theme);
        Changed?.Invoke(theme);
    }

    /// <summary>Keeps one window's root on the current choice, and lets go when the window closes.</summary>
    public static void Follow(FrameworkElement? root, Window window)
    {
        Apply(root, AppSettings.Load().Theme);
        void OnChanged(string theme) => Apply(root, theme);
        Changed += OnChanged;
        window.Closed += (_, _) => Changed -= OnChanged;
    }

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
