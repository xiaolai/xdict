// Lookup: the capture shortcut and its rebinding. The tray's own items and hover are the shell's; the shortcut is the
// one setting this pane owns.
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using XDict.Models;
using Windows.System;
using Windows.UI.Core;

namespace XDict.App;

public sealed partial class LookupView : UserControl
{
    private readonly Capture.CaptureController? capture;
    private uint proposedModifiers;
    private uint proposedKey;

    public LookupView(Capture.CaptureController? capture)
    {
        InitializeComponent();
        this.capture = capture;
        Heading.Text = Strings.Get("settings.lookup");
        HotkeyLabel.Text = Strings.Get("settings.hotkey");
        ChangeHotkeyButton.Content = Strings.Get("settings.changeHotkey");
        ShowHotkey();
    }

    private void ShowHotkey()
    {
        CaptureSettings chord = capture?.Settings ?? CaptureSettings.Load();
        HotkeyText.Text = CaptureSettings.Describe(chord.Modifiers, chord.Key);
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
            Status.Text = Strings.Format("library.failed", Strings.Get("settings.changeHotkey"), error.Message);
        }
    }

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
}
