// General (ADR-0012): the theme, start at login, the lookup shortcut and the acknowledgements.
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI.Core;
using XDict.Models;

namespace XDict.App;

public sealed partial class GeneralView : UserControl
{
    private readonly Capture.CaptureController? capture;
    private bool loading = true;
    private uint proposedModifiers;
    private uint proposedKey;

    public GeneralView(Capture.CaptureController? capture)
    {
        InitializeComponent();
        this.capture = capture;
        AppSettings settings = AppSettings.Load();
        Heading.Text = Strings.Get("settings.general");
        ThemeLabel.Text = Strings.Get("settings.theme");
        Theme.Items.Add(Strings.Get("settings.theme.system"));
        Theme.Items.Add(Strings.Get("settings.theme.light"));
        Theme.Items.Add(Strings.Get("settings.theme.dark"));
        Theme.SelectedIndex = settings.Theme switch { "light" => 1, "dark" => 2, _ => 0 };
        StartAtLogin.Header = Strings.Get("settings.startAtLogin");
        StartAtLogin.IsOn = StartupRegistration.IsEnabled();
        HotkeyLabel.Text = Strings.Get("settings.hotkey");
        ChangeHotkeyButton.Content = Strings.Get("settings.changeHotkey");
        AcknowledgementsButton.Content = Strings.Get("settings.acknowledgements");
        ShowHotkey();
        loading = false;
    }

    private void ShowHotkey()
    {
        CaptureSettings chord = capture?.Settings ?? CaptureSettings.Load();
        HotkeyText.Text = CaptureSettings.Describe(chord.Modifiers, chord.Key);
    }

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading) return;
        string theme = Theme.SelectedIndex switch { 1 => "light", 2 => "dark", _ => "system" };
        // A read-only, locked or full settings file must not end the app from a click.
        try { (AppSettings.Load() with { Theme = theme }).Save(); }
        catch (Exception error) { Status.Text = Strings.Format("settings.saveFailed", error.Message); }
        ThemeApplier.Apply(App.CurrentRoot, theme);
        ThemeApplier.Apply(XamlRoot?.Content as FrameworkElement, theme);
    }

    private void OnStartAtLoginToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        bool wanted = StartAtLogin.IsOn;
        if (StartupRegistration.Set(wanted))
        {
            try { (AppSettings.Load() with { StartAtLogin = wanted }).Save(); }
            catch (Exception error) { Status.Text = Strings.Format("settings.saveFailed", error.Message); }
            return;
        }
        // Put the switch back without re-entering this handler: a failed write in both directions used to
        // ping-pong until the stack overflowed.
        loading = true;
        StartAtLogin.IsOn = !wanted;
        loading = false;
        Status.Text = Strings.Get("settings.startupFailed");
    }

    private async void OnChangeHotkey(object sender, RoutedEventArgs e)
    {
        if (capture is null) { Status.Text = Strings.Get("settings.unavailable"); return; }
        var field = new TextBox { PlaceholderText = Strings.Get("settings.pressKeys"), IsReadOnly = true };
        field.KeyDown += (_, args) =>
        {
            VirtualKey key = args.Key;
            if (key is VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu or VirtualKey.LeftWindows or VirtualKey.RightWindows) return;
            uint modifiers = 0;
            if (Down(VirtualKey.Control)) modifiers |= 0x0002;
            if (Down(VirtualKey.Menu)) modifiers |= 0x0001;
            if (Down(VirtualKey.Shift)) modifiers |= 0x0004;
            if (Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows)) modifiers |= 0x0008;
            if (modifiers == 0) { Status.Text = Strings.Get("settings.modifierRequired"); return; }
            proposedModifiers = modifiers;
            proposedKey = (uint)key;
            field.Text = CaptureSettings.Describe(modifiers, (uint)key);
            args.Handled = true;
        };
        proposedModifiers = 0;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Get("settings.changeHotkey"),
            Content = field,
            PrimaryButtonText = Strings.Get("settings.keep"),
            CloseButtonText = Strings.Get("settings.close"),
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || proposedModifiers == 0) return;
        try
        {
            CaptureSettings kept = capture.Rebind(proposedModifiers, proposedKey);
            HotkeyText.Text = CaptureSettings.Describe(kept.Modifiers, kept.Key);
            Status.Text = "";
        }
        catch (CaptureClashException)
        {
            Status.Text = Strings.Get("capture.clash");
        }
        catch (Exception error)
        {
            // Saving the new chord can fail on a locked or full disk; an async void handler must say so, not end XDict.
            Status.Text = Strings.Format("library.failed", Strings.Get("settings.changeHotkey"), error.Message);
        }
    }

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private async void OnAcknowledgements(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Get("settings.acknowledgements"),
            Content = new ScrollViewer
            {
                MaxHeight = 420,
                Content = new TextBlock { Text = Notices.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
            },
            CloseButtonText = Strings.Get("settings.close"),
        };
        await dialog.ShowAsync();
    }
}
