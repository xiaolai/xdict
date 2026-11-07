#if DEBUG
// The capture lab: the production hotkey, reader, constructor and panel, exercised in the interactive session against a
// real Notepad, with Escape, the tray route, a rebinding and (in its own mode) an elevated window's refusal.
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json;
using XDict.Client;
using XDict.Models;

namespace XDict.App.Capture;

internal static class CaptureLab
{
    private const byte VkShift = 0x10, VkCtrl = 0x11, VkAlt = 0x12;
    private const byte VkEscape = 0x1B, VkHome = 0x24, VkLeft = 0x25, VkRight = 0x27;
    private const uint KeyUp = 0x0002;


    private static void Key(byte vk)
    {
        Win32.keybd_event(vk, 0, 0, UIntPtr.Zero);
        Win32.keybd_event(vk, 0, KeyUp, UIntPtr.Zero);
        Thread.Sleep(40);
    }

    private static void Chord(params byte[] keys)
    {
        foreach (byte key in keys) Win32.keybd_event(key, 0, 0, UIntPtr.Zero);
        for (int i = keys.Length - 1; i >= 0; i--) Win32.keybd_event(keys[i], 0, KeyUp, UIntPtr.Zero);
    }

    public static async Task RunAsync(string configPath, ServiceClient client)
    {
        try
        {
            await RunCoreAsync(configPath, client);
        }
        catch (Exception error)
        {
            string output = "";
            try
            {
                using JsonDocument config = JsonDocument.Parse(await File.ReadAllTextAsync(configPath));
                output = config.RootElement.GetProperty("output").GetString()!;
            }
            catch (Exception) { }
            if (output.Length > 0)
                await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new
                {
                    error = error.GetType().Name + ": " + error.Message,
                    stack = error.StackTrace,
                }));
        }
    }

    private static async Task RunCoreAsync(string configPath, ServiceClient client)
    {
        using JsonDocument config = JsonDocument.Parse(await File.ReadAllTextAsync(configPath));
        JsonElement root = config.RootElement;
        string output = root.GetProperty("output").GetString()!;
        string mode = root.TryGetProperty("mode", out JsonElement modeElement) ? modeElement.GetString()! : "main";
        string settingsPath = root.GetProperty("settings").GetString()!;
        string libraryPath = root.GetProperty("library").GetString()!;
        string textFile = root.GetProperty("text").GetString()!;
        Environment.SetEnvironmentVariable("XDICT_CAPTURE_SETTINGS", settingsPath);
        if (mode is "hover" or "hover-double" or "hover-elevated" or "hover-own" or "hover-own-skip"
            or "hover-ocr" or "hover-noocr" or "hover-stall-uia" or "hover-stall-ocr" or "hover-unaware")
        {
            new CaptureSettings
            {
                Modifiers = 0x0006,
                Key = 0x44,
                Hover = new HoverPolicy
                {
                    Enabled = true,
                    Modifier = HoverModifier.Control,
                    Gesture = mode == "hover-double" ? HoverGesture.DoubleTap : HoverGesture.Hold,
                    SettleMs = 300,
                },
            }.Save(settingsPath);
        }

        var report = new Dictionary<string, object?>();
        string log = output + ".log";
        async Task Mark(string step) => await File.AppendAllTextAsync(log, DateTime.Now.ToString("HH:mm:ss.fff") + " " + step + "\n");
        await Mark("start");
        var store = LibraryStore.Load(libraryPath);
        var session = new SearchSession(client);
        await session.OpenAsync(store.Dictionaries);
        var controller = new CaptureController(client, store, session, (_, _) => { });
        report["hotkeyRegistered"] = controller.Start();
        report["trayVisible"] = controller.TrayVisible;
        report["settingsModifiers"] = controller.Settings.Modifiers;
        report["settingsKey"] = controller.Settings.Key;
        await Mark("controller started");
        report["dictionaries"] = session.Dictionaries.Count;
        // An earlier run can leave a modifier down or a Search flyout in front; either one keeps every target from
        // taking the foreground (measured 2026-11-06: SearchHost in front, and no window could be raised). Release
        // what a chord uses and dismiss the flyout before any target starts.
        foreach (byte key in new byte[] { 0x11, 0x12, 0x10 }) Win32.keybd_event(key, 0, 2, UIntPtr.Zero);
        await Task.Delay(100);
        Key(0x1B);
        await Task.Delay(200);

        Process? target = null;
        IntPtr targetWindow = IntPtr.Zero;
        PdfServer? pdfServer = null;
        PixelsWindow? pixels = null;
        CloakedOverlay? overlay = null;
        bool notepadTarget = false;
        try
        {
        await Mark("target mode " + mode);
        if (mode is "main" or "relaunch" or "notepad" or "word" or "pdf" or "suspended" or "elevated" or "hover" or "hover-double" or "hover-elevated" or "hover-own" or "hover-own-skip"
            or "hover-ocr" or "hover-noocr" or "hover-stall-uia" or "hover-stall-ocr" or "hover-unaware")
        {
            bool elevated = mode is "elevated" or "hover-elevated";
            bool notepad = mode is "notepad" or "elevated" or "hover" or "hover-double" or "hover-elevated" or "hover-own" or "hover-own-skip";
            bool word = mode == "word";
            notepadTarget = notepad;
            bool image = mode is "hover-ocr" or "hover-noocr" or "hover-stall-uia" or "hover-stall-ocr"
                or "hover-unaware";
            // A Word the harness opened through COM is used as it is; starting WINWORD.EXE shows the Start screen.
            if (mode == "pdf") pdfServer = new PdfServer(textFile);
            // The OCR passes read a plain window that draws one word: no text pattern and no name, so the pixels are
            // the only answer. Edge's PDF viewer is not such a surface — its accessibility tree occludes the drawing
            // with a text layer of its own, which would exercise Edge's OCR, not XDict's. Only those passes read the
            // file: a Word or PDF pass hands the document to its own app, which holds it open (measured 2026-11-07:
            // the lab failed on the .docx Word had locked before it opened any target).
            if (image)
            {
                string wordText = File.ReadAllText(textFile).Trim();
                pixels = new PixelsWindow(wordText.Length == 0 ? "recognize" : wordText, unaware: mode == "hover-unaware");
            }
            target = notepad ? (elevated ? FindElevatedNotepad() : StartNotepad(textFile))
                : word ? WordHost(textFile)
                : image ? null
                : StartEdge(pdfServer is not null ? pdfServer.Url : textFile,
                    Path.Combine(Path.GetDirectoryName(Path.GetFullPath(output))!, "edge-profile"));
            report["pdfUrl"] = pdfServer?.Url;
            if (target is null && pixels is null) { report["error"] = "no target window"; await WriteAsync(output, report); return; }
            targetWindow = pixels?.Handle ?? (notepad ? NotepadWindow(15000) : word ? WordWindow(15000) : BrowserWindow(15000));
            if (targetWindow == IntPtr.Zero)
            {
                report["notepads"] = Process.GetProcessesByName("notepad").Select(process => process.Id).ToArray();
                report["error"] = DesktopLocked()
                    ? "the desktop is locked; unlock the host and rerun"
                    : "the target opened no window";
                await WriteAsync(output, report);
                return;
            }
            bool focused = pixels is not null || mode == "hover-elevated" || Focus(targetWindow);
            if (!focused)
            {
                report["notepads"] = Process.GetProcessesByName("notepad").Select(process => process.Id).ToArray();
                report["startedId"] = target?.Id;
                report["startedExited"] = target?.HasExited;
                report["startedMainWindow"] = target?.MainWindowHandle.ToInt64();
                report["foundWindow"] = target is null ? 0 : Win32.MainWindowOf((uint)target.Id).ToInt64();
                IntPtr foreground = Win32.GetForegroundWindow();
                Win32.GetWindowThreadProcessId(foreground, out uint foregroundPid);
                var name = new char[128];
                int length = Win32.GetClassNameW(foreground, name, name.Length);
                report["foreground"] = foreground.ToInt64();
                report["foregroundPid"] = foregroundPid;
                report["foregroundClass"] = new string(name, 0, length);
                report["error"] = DesktopLocked()
                    ? "the desktop is locked; unlock the host and rerun"
                    : "the target did not come to the foreground";
                await WriteAsync(output, report);
                return;
            }
            await Task.Delay(400);
            if (mode is "notepad" or "word" or "pdf" or "hover" or "hover-double" or "hover-own" or "hover-own-skip")
            {
                if (mode == "word")
                {
                    // Office's "sign in to set up Office" dialog is modal over the document; close it by its own button.
                    bool dismissed = false;
                    long until = Environment.TickCount64 + 15000;
                    while (!dismissed && Environment.TickCount64 < until)
                    {
                        dismissed = DismissOfficeDialog(targetWindow);
                        if (!dismissed) Thread.Sleep(500);
                    }
                    report["officeDialogDismissed"] = dismissed;
                    Thread.Sleep(800);
                    Focus(targetWindow);
                }
                // **The document holding the fixture must be the front one.** Windows 11's Notepad restores its
                // tabs, so the file the lab opened can sit behind a restored start page and the pass would read
                // another document's text (measured 2026-11-07: a term of 'x' from a document that was not the
                // fixture's). The loop is bounded and its outcome is recorded, never assumed.
                await Mark("closing restored tabs");
                report["tabsClosed"] =
                    OnSta(() => CloseForeignTabs(targetWindow, Path.GetFileName(textFile)));
                await Mark("tabs: " + report["tabsClosed"]);
                report["frontDocument"] = EnsureFrontDocument(targetWindow, Path.GetFileName(textFile), FixtureSentence);
                await Mark("front: " + report["frontDocument"]);
                ClickDocument(targetWindow);
                if (mode == "word") report["wordElements"] = OnSta(() => DescribeTree(targetWindow));
                // Notepad restores its tabs, and how a tab is named is what the fixture's tab is chosen by.
                if (mode is "notepad" or "hover" or "hover-double" or "hover-own" or "hover-own-skip")
                    report["hostTree"] = OnSta(() => DescribeTree(targetWindow));
                if (mode == "pdf")
                {
                    report["pdfElements"] = OnSta(() => DescribeTree(targetWindow));
                    report["pdfDocuments"] = OnSta(() => DescribeDocuments(targetWindow));
                }
                report["documentFocus"] = OnSta(() => System.Windows.Automation.AutomationElement.FocusedElement?.Current.ControlType.ProgrammaticName ?? "");
                report["selectionAfterSelection"] = OnSta(() => SelectWordByUia(targetWindow, "run"));
                report["documentText"] = OnSta(() => DescribeDocuments(targetWindow));
                report["focusAfterSelection"] = OnSta(() => System.Windows.Automation.AutomationElement.FocusedElement?.Current.ControlType.ProgrammaticName ?? "");
            }
            else if (mode is "main" or "relaunch" or "suspended") ClickCenter(targetWindow);
            await Mark("selection made");
            report["foregroundBefore"] = Win32.GetForegroundWindow().ToInt64();
        }

        if (mode is "hover" or "hover-double")
        {
            report["hoverRunning"] = controller.HoverRunning;
            report["hoverStartFailed"] = controller.HoverStartFailed;
            report["hoverModifier"] = controller.Hover.Modifier.ToString();
            report["hoverGesture"] = controller.Hover.Gesture.ToString();
            report["hoverSettle"] = controller.Hover.SettleMs;
            // The hover reads the word's rectangle in the front document, so that document must be the fixture's —
            // and **by a word only the hover fixture holds**: 'run' alone is in every fixture, and a restored
            // capture-lab tab was accepted as the hover one (measured 2026-11-07).
            report["tabsClosed"] = OnSta(() => CloseForeignTabs(targetWindow, Path.GetFileName(textFile)));
            report["frontDocument"] = EnsureFrontDocument(targetWindow, Path.GetFileName(textFile), FixtureSentence, "alpha beta gamma");
            var word = OnSta(() => WordRectByUia(targetWindow, 1));
            report["hoverWord"] = word.Text;
            if (word.Rect is { } box)
            {
                int x = (int)(box.X + box.Width / 2), y = (int)(box.Y + box.Height / 2);
                report["hoverPoint"] = new[] { x, y };
                Win32.SetCursorPos(x - 3, y);
                await Task.Delay(100);
                Win32.SetCursorPos(x, y);
                await Task.Delay(150);
                Win32.GetCursorPos(out Win32.POINT cursor);
                report["hoverCursor"] = new[] { cursor.X, cursor.Y };
                IntPtr hit = Win32.WindowFromPoint(new Win32.POINT { X = x, Y = y });
                Win32.GetWindowThreadProcessId(hit, out uint hitPid);
                report["hoverWindow"] = hit.ToInt64();
                report["hoverWindowPid"] = hitPid;
                report["hoverWindowRoot"] = Win32.GetAncestor(hit, Win32.GA_ROOT).ToInt64();
                long started = Environment.TickCount64;
                if (mode == "hover-double")
                {
                    Key(0x11);
                    Thread.Sleep(80);
                    Key(0x11);
                }
                else
                {
                    Win32.keybd_event(0x11, 0, 0, UIntPtr.Zero); // Ctrl down
                }
                long deadline = Environment.TickCount64 + 6000;
                while (controller.Panel is not { Shown: true } && Environment.TickCount64 < deadline)
                    await Task.Delay(10);
                report["hoverPanelMs"] = controller.Panel is { Shown: true } ? Environment.TickCount64 - started : -1;
                report["hoverShown"] = controller.Panel is { Shown: true };
                report["hoverTerm"] = controller.Panel?.Term;
                report["hoverRefusal"] = controller.LastRefusal;
                report["hoverFailure"] = controller.LastFailure;
                report["hoverNotice"] = controller.HoverNotice;
                report["hoverHookMicroseconds"] = controller.HoverHookMicroseconds;
            report["hoverLastOutcome"] = controller.HoverLastOutcome;
            report["hoverLastReadMs"] = controller.HoverLastReadMs;
            report["hoverReadsStarted"] = controller.HoverReadsStarted;
            report["hoverWordsFound"] = controller.HoverWordsFound;
            report["hoverEventsSeen"] = controller.HoverEventsSeen;
            report["hoverModifierDowns"] = controller.HoverModifierDowns;
            report["hoverLastEvent"] = controller.HoverLastEvent;
            report["hoverArmed"] = controller.HoverArmed;
            report["hoverModifierHeld"] = controller.HoverModifierHeld;
                long ack = Environment.TickCount64 + 5000;
                while (controller.Panel is { Shown: true } && controller.LastAcknowledgement is null &&
                       Environment.TickCount64 < ack) await Task.Delay(20);
                report["hoverAck"] = controller.LastAcknowledgement?.Outcome.ToString();
                report["hoverFocusUnchanged"] = controller.LastFocusUnchanged;
                if (mode != "hover-double") Win32.keybd_event(0x11, 0, 2, UIntPtr.Zero);
                // The release must be processed before Escape: an Escape that arrives with Ctrl still down is
                // Ctrl+Esc, which opens the Start menu and takes the foreground from every later target.
                await Task.Delay(150);
                Key(0x1B);
                await Task.Delay(400);
                report["hoverDismissedByEscape"] = controller.Panel is not { Shown: true };
                // Without the key, the same rest asks nothing.
                Win32.SetCursorPos(x - 40, y);
                await Task.Delay(100);
                Win32.SetCursorPos(x, y);
                await Task.Delay(1300);
                report["hoverPanelWithoutKey"] = controller.Panel is { Shown: true };
                // Idle cost with the hooks installed and no input: the watcher's timer and the hooks' own wake-ups.
                Process self = Process.GetCurrentProcess();
                TimeSpan cpuBefore = self.TotalProcessorTime;
                long wallBefore = Environment.TickCount64;
                await Task.Delay(3000);
                double wall = Math.Max(1, Environment.TickCount64 - wallBefore);
                double cpu = (self.TotalProcessorTime - cpuBefore).TotalMilliseconds / wall /
                    Environment.ProcessorCount * 100;
                report["hoverIdleCpuPercent"] = Math.Round(cpu, 3);
            }
        }

        if (mode is "hover-own" or "hover-own-skip")
        {
#if DEBUG
            if (mode == "hover-own-skip") Environment.SetEnvironmentVariable("XDICT_HOVER_SKIP_OWN", "1");
#endif
            report["ownRunning"] = controller.HoverRunning;
            report["ownStartFailed"] = controller.HoverStartFailed;
            _ = controller.AskAsync(CaptureTrigger.Selection);
            long until = Environment.TickCount64 + 6000;
            while (controller.Panel is not { Shown: true } && Environment.TickCount64 < until)
                await Task.Delay(20);
            report["ownPanel"] = controller.Panel is { Shown: true };
            report["ownSelectionTerm"] = controller.Panel?.Term;
            // The fixture's document must be the front tab here too, found by the word this pass needs: a restored
            // start page or another run's tab in front left the scan with no such word (measured 2026-11-07).
            report["tabsClosed"] = OnSta(() => CloseForeignTabs(targetWindow, Path.GetFileName(textFile)));
            report["frontDocument"] = EnsureFrontDocument(targetWindow, Path.GetFileName(textFile), FixtureSentence, "alpha beta gamma");
            var gamma = OnSta(() => FindWordRectByUia(targetWindow, "gamma"));
            report["ownPlannedWord"] = gamma.Text;
            report["ownPlannedRect"] = gamma.Rect is { } planned
                ? new[] { (int)planned.X, (int)planned.Y, (int)planned.Width, (int)planned.Height } : null;
            // Defaults, so a case the pass could not set up is a named failure in the stage and never a missing
            // property: the last time this branch stopped early, the stage reported a PowerShell error instead.
            report["ownTermRectFound"] = false;
            report["ownHoverTerm"] = null;
            report["ownHoverRequest"] = null;
            report["ownHoverAck"] = null;
            if (gamma.Rect is { } rect && controller.Panel is { Shown: true })
            {
                // Put the panel's term over `gamma`, so the word behind it differs from the panel's own word.
                controller.Panel.ShowAt(new SelectionBox((int)rect.X, (int)(rect.Y - 43), 1, 1));
                // The panel's own tree is rebuilt as it moves; a rectangle read too early is no rectangle at all.
                System.Windows.Rect? term = null;
                for (long wait = Environment.TickCount64 + 2000; Environment.TickCount64 < wait; )
                {
                    await Task.Delay(100);
                    term = OnSta(PanelTermRect);
                    if (term is not null) break;
                }
                report["ownTermRect"] = term is { } t0 ? new[] { (int)t0.X, (int)t0.Y, (int)t0.Width, (int)t0.Height } : null;
                report["ownTermRectFound"] = term is not null;
                if (term is { } box)
                {
                    // The title line sits at the top of its block; the block's centre can be over the entry below it.
                    int x = (int)box.X + 24, y = (int)box.Y + 22;
                    report["ownPoint"] = new[] { x, y };
                    report["ownBehindWord"] = OnSta(() => WordAtPoint(targetWindow, x, y));
                    int before = controller.LastAcknowledgement?.Request ?? 0;
                    Win32.SetCursorPos(x, y);
                    await Task.Delay(150);
                    Win32.keybd_event(0x11, 0, 0, UIntPtr.Zero);
                    until = Environment.TickCount64 + 6000;
                    while ((controller.LastAcknowledgement?.Request ?? before) <= before &&
                           Environment.TickCount64 < until) await Task.Delay(20);
                    report["ownHoverTerm"] = controller.Panel?.Term;
                    report["ownHoverRequest"] = controller.LastAcknowledgement?.Request;
                    report["ownHoverAck"] = controller.LastAcknowledgement?.Outcome.ToString();
                    report["ownLastOutcome"] = controller.HoverLastOutcome;
                    report["ownReadMs"] = controller.HoverLastReadMs;
                    report["ownModifierDowns"] = controller.HoverModifierDowns;
                    report["ownEventsSeen"] = controller.HoverEventsSeen;
                    report["ownLastEvent"] = controller.HoverLastEvent;
                    report["ownArmed"] = controller.HoverArmed;
                    report["ownModifierHeld"] = controller.HoverModifierHeld;
                    report["ownLastStillMs"] = controller.HoverLastStillMs;
                    report["ownLastSettleMs"] = controller.HoverLastSettleMs;
                    report["ownSettleChecks"] = controller.HoverSettleChecks;
                    report["ownReading"] = controller.HoverReading;
                    report["ownEnabled"] = controller.HoverEnabledNow;
                    report["ownReadsStarted"] = controller.HoverReadsStarted;
                    report["ownLastEventDelayMs"] = controller.HoverLastEventDelayMs;
                    report["ownLastTerm"] = controller.HoverLastWord?.Term;
                    report["ownLastAcquisition"] = controller.HoverLastWord?.Acquisition;
                    report["ownLastSource"] = controller.HoverLastWord?.SourceName;
                    report["ownLastPid"] = controller.HoverLastWord?.SourceId;
                    report["ownLastSentence"] = controller.HoverLastWord?.Sentence;
                    report["ownLastBox"] = controller.HoverLastWord?.Box;
                    Win32.keybd_event(0x11, 0, 2, UIntPtr.Zero);
                    await Task.Delay(150);
                    Key(0x1B);
                    await Task.Delay(300);
                }
            }
        }

        if (mode is "hover-ocr" or "hover-noocr" or "hover-stall-uia" or "hover-stall-ocr" or "hover-unaware"
            or "hover-elevated")
        {
            report["specialRunning"] = controller.HoverRunning;
            report["specialStartFailed"] = controller.HoverStartFailed;
            int x = 0, y = 0;
            IntPtr main = IntPtr.Zero;
            if (mode == "hover-elevated")
            {
                if (!Win32.GetWindowRect(targetWindow, out Win32.RECT windowRect))
                {
                    report["error"] = "the elevated target has no window rectangle";
                    await WriteAsync(output, report);
                    return;
                }
                x = (windowRect.Left + windowRect.Right) / 2;
                y = windowRect.Top + Math.Min(200, (windowRect.Bottom - windowRect.Top) / 2);
                // UIPI refuses the key while an elevated window holds the foreground, and a medium process cannot
                // take it back. The elevated launcher is asked to focus this window and press the key instead; it
                // parked the target topmost over the pointer, which is the case the reader must refuse.
                main = Win32.MainWindowOf((uint)Environment.ProcessId);
                if (main != IntPtr.Zero)
                {
                    int parkX = windowRect.Right + 40, parkY = windowRect.Top + 40;
                    Win32.RECT around = windowRect;
                    IntPtr monitor = Win32.MonitorFromRect(ref around, Win32.MONITOR_DEFAULTTONEAREST);
                    var info = new Win32.MONITORINFO { cbSize = (uint)Marshal.SizeOf<Win32.MONITORINFO>() };
                    if (Win32.GetMonitorInfoW(monitor, ref info))
                    {
                        parkX = info.rcWork.Right - 460;
                        parkY = info.rcWork.Bottom - 300;
                    }
                    Win32.SetWindowPos(main, IntPtr.Zero, parkX, parkY, 420, 240, Win32.SWP_SHOWWINDOW);
                    Thread.Sleep(250);
                    report["mainWindow"] = DescribeWindow(main);
                    report["mainVisible"] = Win32.IsWindowVisible(main);
                    report["mainRect"] = Win32.GetWindowRect(main, out Win32.RECT moved)
                        ? new[] { moved.Left, moved.Top, moved.Right - moved.Left, moved.Bottom - moved.Top } : null;
                }
                report["elevatedFocus"] = Win32.GetForegroundWindow().ToInt64();
                report["elevatedFocusName"] = DescribeWindow(Win32.GetForegroundWindow());
            }
            else
            {
                if (pixels is null || !Win32.GetWindowRect(pixels.Handle, out Win32.RECT pixelsRect))
                {
                    report["error"] = "the pixels surface has no window rectangle";
                    await WriteAsync(output, report);
                    return;
                }
                // The word is drawn at the window's centre, so the centre is the point — invariant under the DPI
                // scaling a dpi-unaware window's surface gets.
                x = (pixelsRect.Left + pixelsRect.Right) / 2;
                y = (pixelsRect.Top + pixelsRect.Bottom) / 2;
                report["pixelsRect"] = new[]
                {
                    pixelsRect.Left, pixelsRect.Top, pixelsRect.Right - pixelsRect.Left,
                    pixelsRect.Bottom - pixelsRect.Top,
                };
                // The overlay the read must skip, made here above the surface's centre: DWM draws none of it, Win32
                // says it is visible, and it is topmost. The host cannot be relied on to have one on screen.
                overlay = new CloakedOverlay("cloak", x, y);
                report["overlayWindow"] = DescribeWindow(overlay.Handle);
                report["overlaySet"] = overlay.CloakResult;
                report["overlayCloaked"] = overlay.Cloaked;
                report["overlayRaised"] = overlay.Raised;
                // **The z-order the read will walk is the condition under test, so it is established here, not
                // assumed.** A topmost window does not always land above an earlier topmost one (measured
                // 2026-11-07: raised, cloaked, and enumerated below the surface), so it is raised again until the
                // read's own enumeration sees it above — and how many raises that took is recorded.
                int raises = 0;
                for (; raises < 10 && CloakedAbove(targetWindow, x, y) is null; raises++)
                {
                    Win32.SetWindowPos(overlay.Handle, Win32.HWND_TOPMOST, x - 300, y - 150, 600, 300,
                        Win32.SWP_NOACTIVATE | Win32.SWP_SHOWWINDOW);
                    Thread.Sleep(60);
                }
                report["overlayRaises"] = raises;
                report["overlayTopmost"] =
                    ((long)Win32.GetWindowLongPtrW(overlay.Handle, Win32.GWL_EXSTYLE) & Win32.WS_EX_TOPMOST) != 0;
            }
            report["specialPoint"] = new[] { x, y };
            // The overlay the read must skip, named before the read: a pass asserts it was there and still lost.
            report["aboveTarget"] = AboveInventory(targetWindow, x, y);
            report["cloakedAtPoint"] = CloakedAtPoint(x, y);
            // Only an overlay **above** the target exercises the skip: one below it would never have won the read.
            report["cloakedAbove"] = CloakedAbove(targetWindow, x, y);
            report["pointWindow"] = DescribeWindow(HoverReader.TopWindowAt(x, y));
            // What the read would fall back to behind the surface. A negative pass asserts it is nothing: any app
            // there is an answer the product is right to give, so the fixture — not the product — is what failed.
            report["behindWindow"] = pixels is null ? null : DescribeWindow(HoverReader.FirstOrdinaryBehind(pixels.Handle, x, y));
            if (pixels is not null)
            {
                report["pixelsVisible"] = Win32.IsWindowVisible(pixels.Handle);
                report["pixelsCloaked"] = Win32.IsCloaked(pixels.Handle);
                report["pixelsIconic"] = Win32.IsIconic(pixels.Handle);
                report["pixelsAwareness"] = Win32.GetWindowDpiAwarenessContext(pixels.Handle).ToInt64();
                report["pixelsMonitorDpi"] = Win32.MonitorDpi(pixels.Handle);
            }
#if DEBUG
            if (mode == "hover-noocr") Environment.SetEnvironmentVariable("XDICT_HOVER_NO_OCR", "1");
            if (mode == "hover-stall-uia") Environment.SetEnvironmentVariable("XDICT_HOVER_STALL_UIA", "5000");
            if (mode == "hover-stall-ocr") Environment.SetEnvironmentVariable("XDICT_HOVER_STALL_OCR", "6000");
            Environment.SetEnvironmentVariable("XDICT_HOVER_CAPTURE_DUMP", output + ".capture.png");
#endif
            Win32.SetCursorPos(x - 3, y);
            await Task.Delay(120);
            Win32.SetCursorPos(x, y);
            await Task.Delay(180);
            long started = Environment.TickCount64;
            string? press = root.TryGetProperty("press", out JsonElement pressElement) ? pressElement.GetString() : null;
            bool external = mode == "hover-elevated" && press is not null;
            if (external)
            {
                report["externalPress"] = true;
                // The launcher needs this window's handle to take the foreground before pressing: the press itself
                // is ignored while an elevated window owns it.
                File.WriteAllText(press!,
                    main == IntPtr.Zero ? "" : main.ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture));
            }
            else
            {
                Win32.keybd_event(0x11, 0, 0, UIntPtr.Zero);
            }
            long deadline = started + 9000;
            while (controller.Panel is not { Shown: true } && string.IsNullOrEmpty(controller.HoverNotice) &&
                   Environment.TickCount64 < deadline) await Task.Delay(20);
            report["specialPanelMs"] = controller.Panel is { Shown: true } ? Environment.TickCount64 - started : -1;
            report["specialShown"] = controller.Panel is { Shown: true };
            report["specialTerm"] = controller.Panel?.Term;
            report["specialAcquisition"] = controller.HoverLastWord?.Acquisition;
            report["specialSource"] = controller.HoverLastWord?.SourceName;
            report["specialReadMs"] = controller.HoverLastReadMs;
            report["specialOutcome"] = controller.HoverLastOutcome;
            report["specialDiagnostics"] = controller.HoverLastDiagnostics;
            report["specialLastTerm"] = controller.HoverLastWord?.Term;
            report["specialLastBox"] = controller.HoverLastWord?.Box;
            report["specialNotice"] = controller.HoverNotice;
            report["specialEvents"] = controller.HoverEventsSeen;
            report["specialModifierDowns"] = controller.HoverModifierDowns;
            report["specialArmed"] = controller.HoverArmed;
            report["specialModifierHeld"] = controller.HoverModifierHeld;
            report["specialLastEvent"] = controller.HoverLastEvent;
            report["specialSettleChecks"] = controller.HoverSettleChecks;
            report["specialHookMicroseconds"] = controller.HoverHookMicroseconds;
            long ackDeadline = Environment.TickCount64 + 5000;
            while (controller.Panel is { Shown: true } && controller.LastAcknowledgement is null &&
                   Environment.TickCount64 < ackDeadline) await Task.Delay(20);
            report["specialAck"] = controller.LastAcknowledgement?.Outcome.ToString();
            report["specialRequest"] = controller.LastAcknowledgement?.Request;
            if (!external) Win32.keybd_event(0x11, 0, 2, UIntPtr.Zero);
            await Task.Delay(150);
            Key(0x1B);
            await Task.Delay(500);
            report["specialDismissed"] = controller.Panel is not { Shown: true };
#if DEBUG
            if (mode == "hover-stall-uia" || mode == "hover-stall-ocr")
            {
                Environment.SetEnvironmentVariable(
                    mode == "hover-stall-uia" ? "XDICT_HOVER_STALL_UIA" : "XDICT_HOVER_STALL_OCR", null);
                // The stalled lane owns the capture until its own work ends (the OCR task sleeps 6 s); let it return.
                await Task.Delay(7000);
                int before = controller.LastAcknowledgement?.Request ?? 0;
                int rx = x, ry = y;
                if (mode == "hover-stall-uia")
                {
                    // **A UIA-only target for the recovery read**: a blank window whose word is its title. OCR can
                    // answer nothing on it, so a word proves the UIA worker answered again — the pixels surface the
                    // first phase used would let a OCR hit stand in for a lane that never recovered.
                    using var only = new PixelsWindow("resume", uiaOnly: true);
                    if (!Win32.GetWindowRect(only.Handle, out Win32.RECT onlyRect))
                    {
                        report["error"] = "the UIA-only recovery window has no rectangle";
                        await WriteAsync(output, report);
                        return;
                    }
                    rx = (onlyRect.Left + onlyRect.Right) / 2;
                    ry = (onlyRect.Top + onlyRect.Bottom) / 2;
                    report["recoveryUiaOnlyRect"] = new[]
                    {
                        onlyRect.Left, onlyRect.Top, onlyRect.Right - onlyRect.Left, onlyRect.Bottom - onlyRect.Top,
                    };
                    Win32.SetCursorPos(rx - 3, ry);
                    await Task.Delay(120);
                    Win32.SetCursorPos(rx, ry);
                    await Task.Delay(180);
                    Win32.keybd_event(0x11, 0, 0, UIntPtr.Zero);
                    deadline = Environment.TickCount64 + 7000;
                    while ((controller.LastAcknowledgement?.Request ?? before) <= before &&
                           Environment.TickCount64 < deadline) await Task.Delay(20);
                }
                else
                {
                    Win32.SetCursorPos(x - 3, y);
                    await Task.Delay(120);
                    Win32.SetCursorPos(x, y);
                    await Task.Delay(180);
                    Win32.keybd_event(0x11, 0, 0, UIntPtr.Zero);
                    deadline = Environment.TickCount64 + 7000;
                    while ((controller.LastAcknowledgement?.Request ?? before) <= before &&
                           Environment.TickCount64 < deadline) await Task.Delay(20);
                }
                report["recoveryShown"] = controller.Panel is { Shown: true };
                report["recoveryTerm"] = controller.Panel?.Term;
                report["recoveryReadMs"] = controller.HoverLastReadMs;
                report["recoveryAck"] = controller.LastAcknowledgement?.Outcome.ToString();
                report["recoveryRequest"] = controller.LastAcknowledgement?.Request;
                report["recoveryAcquisition"] = controller.HoverLastWord?.Acquisition;
                report["recoveryStuckReads"] = controller.HoverStuckReads;
                report["recoveryOutcome"] = controller.HoverLastOutcome;
                report["recoveryHookMicroseconds"] = controller.HoverHookMicroseconds;
                Win32.keybd_event(0x11, 0, 2, UIntPtr.Zero);
                await Task.Delay(150);
                Key(0x1B);
                await Task.Delay(300);
            }
#endif
        }

        if (mode is "main" or "relaunch" or "notepad" or "word" or "pdf" or "suspended" or "elevated")
        {
            uint modifiers = controller.Settings.Modifiers, key = controller.Settings.Key;
            bool paused = false;
            if (mode == "suspended")
            {
                // The panel must reach the screen even when the dictionary service is frozen.
                paused = Win32.Suspend(client.ProcessId, true);
                report["serviceSuspended"] = paused;
            }
            long started = Environment.TickCount64;
            await Mark("sending chord");
            // UIPI drops synthetic keys sent to an elevated window, so that case asks through the tray's own route.
            if (mode == "elevated") _ = controller.AskAsync(CaptureTrigger.Menu);
            else Chord(ModifierVk(modifiers, 0x11), ModifierVk(modifiers, 0x12), ModifierVk(modifiers, 0x10), (byte)key);
            await Mark("chord sent");
            long deadline = Environment.TickCount64 + 3000;
            while (controller.Panel is not { Shown: true } && Environment.TickCount64 < deadline) await Task.Delay(10);
            report["pressedModifiers"] = modifiers;
            report["pressedKey"] = key;
            report["panelShown"] = controller.Panel is { Shown: true };
            report["panelMs"] = controller.Panel is { Shown: true } ? Environment.TickCount64 - started : -1;
            long ackDeadline = Environment.TickCount64 + 8000;
            while (controller.Panel is { Shown: true } && controller.LastAcknowledgement is null &&
                   Environment.TickCount64 < ackDeadline) await Task.Delay(20);
            report["term"] = controller.Panel?.Term;
            report["refusal"] = controller.LastRefusal;
            report["focusInfo"] = controller.LastFocusInfo;
            report["foregroundAfterShowImmediate"] = controller.LastForegroundAfterShow;
            report["panelHandle"] = controller.PanelHandle;
            report["focusUnchanged"] = controller.LastFocusUnchanged;
            report["foregroundAfterShow"] = Win32.GetForegroundWindow().ToInt64();
            report["acknowledgement"] = controller.LastAcknowledgement?.Outcome.ToString();
            if (paused)
            {
                Win32.Suspend(client.ProcessId, false);
                report["serviceResumed"] = true;
            }
            report["acknowledgementGeneration"] = controller.LastAcknowledgement?.Generation;
            report["foregroundAfter"] = Win32.GetForegroundWindow().ToInt64();
            report["targetForeground"] = Win32.GetForegroundWindow() == targetWindow;

            if (mode != "elevated" && controller.Panel is { Shown: true })
            {
                Key(VkEscape);
                await Task.Delay(300);
                report["dismissedByEscape"] = controller.Panel is not { Shown: true };
                report["foregroundAfterEscape"] = Win32.GetForegroundWindow().ToInt64();
                report["targetStillForeground"] = Win32.GetForegroundWindow() == targetWindow;
                // The next key must reach the host app. A character proves it where the host is the lab's own page;
                // a **document that outlives the pass is never edited**: typing 'X' over the selected word replaced
                // it, and the next pass read "The x reader" (measured 2026-11-07). A plain editor gets an arrow key,
                // which moves the caret and changes no text.
                bool disposableHost = mode is "main" or "relaunch" or "suspended";
                report["hostKeyProbe"] = disposableHost ? "X" : "Right";
                Key(disposableHost ? (byte)0x58 : (byte)0x27);
                await Task.Delay(200);
                report["hostReceivedKey"] = Win32.GetForegroundWindow() == targetWindow;

                // A click outside the panel dismisses it, and the host app keeps the foreground.
                Chord(ModifierVk(modifiers, 0x11), ModifierVk(modifiers, 0x12), ModifierVk(modifiers, 0x10), (byte)key);
                long secondDeadline = Environment.TickCount64 + 3000;
                while (controller.Panel is not { Shown: true } && Environment.TickCount64 < secondDeadline) await Task.Delay(10);
                bool secondShown = controller.Panel is { Shown: true };
                ClickCenter(targetWindow);
                await Task.Delay(400);
                report["panelShownAgain"] = secondShown;
                report["dismissedByClickAway"] = secondShown && controller.Panel is not { Shown: true };
                report["foregroundAfterClickAway"] = Win32.GetForegroundWindow().ToInt64();
                report["targetAfterClickAway"] = Win32.GetForegroundWindow() == targetWindow;
            }
        }

        if (mode == "main")
        {
            // The tray's own route runs the same capture path.
            controller.RunTrayCommand(1);
            long trayDeadline = Environment.TickCount64 + 3000;
            while (controller.Panel is not { Shown: true } && Environment.TickCount64 < trayDeadline) await Task.Delay(10);
            report["trayLookupShown"] = controller.Panel is { Shown: true };
            controller.Panel?.Dismiss();

            // A rebinding is saved; the relaunch pass reads it back and presses the new chord.
            CaptureSettings rebound = controller.Rebind(0x0002 | 0x0001 | 0x0004, 0x4B); // Ctrl+Alt+Shift+K
            report["reboundModifiers"] = rebound.Modifiers;
            report["reboundKey"] = rebound.Key;
            report["reboundRegistered"] = controller.HotkeyRegistered;
            // A clash: another window holds Ctrl+Alt+D; the rebinding is refused and the old one keeps working.
            using (var other = new Hotkey(() => { }))
            {
                bool otherHolds = other.Register(0x0002 | 0x0001, 0x44);
                report["otherHoldsDefault"] = otherHolds;
                try
                {
                    controller.Rebind(0x0002 | 0x0001, 0x44);
                    report["clashReported"] = false;
                }
                catch (CaptureClashException)
                {
                    report["clashReported"] = true;
                }
                report["settingsAfterClash"] = new[] { controller.Settings.Modifiers, controller.Settings.Key };
            }
        }

        await Mark("writing report");
        await WriteAsync(output, report);
        await Mark("report written");
        }
        finally
        {
            // Every early return (no target window, no foreground) still ends its Notepad/Word/Edge and the server.
            try { target?.Kill(); } catch (Exception) { }
            // Windows 11's Notepad may host the window in a process other than the one started; end the window's own
            // process too, or a failed pass leaves a Notepad the next stage refuses to run beside.
            if (notepadTarget && targetWindow != IntPtr.Zero && target is not null)
            {
                Win32.GetWindowThreadProcessId(targetWindow, out uint owner);
                if (owner != 0 && owner != (uint)Environment.ProcessId && owner != (uint)target.Id)
                {
                    try
                    {
                        using Process windowOwner = Process.GetProcessById((int)owner);
                        // Windows 11's Notepad hosts the window in a second process started with the launcher. A
                        // Notepad that predates this run is the person's and is never killed.
                        bool ours = windowOwner.ProcessName.Equals("notepad", StringComparison.OrdinalIgnoreCase) &&
                            windowOwner.StartTime >= target.StartTime.AddSeconds(-2);
                        if (ours) windowOwner.Kill();
                    }
                    catch (Exception) { }
                }
            }
            // Notepad saves its tab list even when it is killed, so each pass leaves one behind and the next run
            // opens them all in front of its own (measured 2026-11-07: seventeen tabs). Closing the lab's own tabs
            // here keeps that list empty; a person's document matches none of the lab's names and is never touched.
            if (notepadTarget && targetWindow != IntPtr.Zero)
            {
                try { OnSta(() => CloseForeignTabs(targetWindow, "\0none"), 5000); }
                catch (Exception) { }
            }
            overlay?.Dispose();
            pixels?.Dispose();
            pdfServer?.Dispose();
            controller.Dispose();
        }
    }

    private static byte ModifierVk(uint modifiers, byte key) => (modifiers & KeyMask(key)) != 0 ? key : (byte)0;

    private static uint KeyMask(byte key) => key switch
    {
        0x11 => 0x0002, // Ctrl
        0x12 => 0x0001, // Alt
        0x10 => 0x0004, // Shift
        _ => 0,
    };

    private static Process? FirstProcess(string name) => Process.GetProcessesByName(name).FirstOrDefault();

    /// <summary>A running COM-opened Word is reused; otherwise WINWORD.EXE is started (its Start screen is a risk).</summary>
    private static Process? WordHost(string document) =>
        WordWindow(1500) != IntPtr.Zero ? FirstProcess("WINWORD") : StartWord(document);

    /// <summary>Word's own frame is class OpusApp; a first-run dialog is another window and is not the document.</summary>
    /// <summary>The first window any of these processes opens, found by `windowOf`, within the deadline.</summary>
    private static IntPtr PollWindow(IEnumerable<string> names, Func<uint, IntPtr> windowOf, int milliseconds)
    {
        long deadline = Environment.TickCount64 + milliseconds;
        while (Environment.TickCount64 < deadline)
        {
            foreach (string name in names)
            {
                foreach (Process process in Process.GetProcessesByName(name))
                {
                    uint pid = (uint)process.Id;
                    process.Dispose();
                    IntPtr window = windowOf(pid);
                    if (window != IntPtr.Zero) return window;
                }
            }
            Thread.Sleep(100);
        }
        return IntPtr.Zero;
    }

    private static IntPtr WordWindow(int milliseconds) =>
        PollWindow(["WINWORD"], pid => Win32.WindowOfClass(pid, "OpusApp"), milliseconds);

    private static Process StartWord(string document)
    {
        string[] candidates =
        [
            @"C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE",
            @"C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE",
            "winword.exe",
        ];
        string? executable = candidates.FirstOrDefault(candidate => candidate == "winword.exe" || File.Exists(candidate));
        if (executable is null) throw new InvalidOperationException("Word is not installed");
        return Process.Start(new ProcessStartInfo(executable, "\"" + document + "\"") { UseShellExecute = true })!;
    }

    /// <summary>The visible window of any process with this name, waiting while it starts.</summary>
    private static IntPtr ProcessWindow(string name, int milliseconds) =>
        PollWindow([name], Win32.MainWindowOf, milliseconds);

    private static Process StartEdge(string htmlFile, string profile)
    {
        string[] candidates =
        [
            @"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
            @"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
            @"C:\Program Files\Google\Chrome\Application\chrome.exe",
        ];
        string? executable = candidates.FirstOrDefault(File.Exists);
        if (executable is null) throw new InvalidOperationException("no Edge or Chrome found");
        // A bare Windows path is a search term to Chromium; a file URI opens the page or the PDF viewer.
        string target = File.Exists(htmlFile) ? new Uri(htmlFile).AbsoluteUri : htmlFile;
        // **Its own profile under the lab folder.** A browser started beside the reader's session hands the page to
        // the running browser and exits, so the process that owns the window carries no lab argument and cleanup
        // cannot tell it from the person's browser (measured 2026-11-07: a lab window survived the run and answered
        // a later pass). A private profile keeps every process of this run's browser carrying the lab path — the
        // cleanup's own evidence — and keeps the person's session out of the fixture.
        Directory.CreateDirectory(profile);
        string arguments = "\"" + target + "\" --user-data-dir=\"" + profile + "\" --no-first-run --no-default-browser-check";
        return Process.Start(new ProcessStartInfo(executable, arguments) { UseShellExecute = true })!;
    }

    private static IntPtr BrowserWindow(int milliseconds) =>
        PollWindow(["msedge", "chrome"], Win32.MainWindowOf, milliseconds);

    /// <summary>Clicks the middle of the client area, so the page holds focus rather than the address bar.</summary>
    private static void ClickCenter(IntPtr window)
    {
        Win32.GetWindowRect(window, out Win32.RECT rect);
        Win32.SetCursorPos((rect.Left + rect.Right) / 2, (rect.Top + rect.Bottom) / 2);
        Thread.Sleep(150);
        Win32.mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        Win32.mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(300);
    }

    /// <summary>The fixture's own word, selected through the text pattern of the document that holds its sentence.
    /// **Not "the second word of the first text pattern in the window"**: a host may expose another document beside
    /// the page (measured 2026-11-07: a selection of 'x' from a document that was not the fixture's), and a selection
    /// from the wrong document is a fixture that proves nothing about the reader.</summary>
    private static string SelectWordByUia(IntPtr window, string word)
    {
        var document = TextDocument(window, word);
        if (document is null) return "<no document holding " + word + ">";
        if (!document.TryGetCurrentPattern(System.Windows.Automation.TextPattern.Pattern, out object raw))
            return "<no text pattern>";
        var text = (System.Windows.Automation.TextPattern)raw;
        System.Windows.Automation.Text.TextPatternRange? found = text.DocumentRange.FindText(word, false, false);
        if (found is null) return "<" + word + " not found in the document>";
        found.Select();
        var selection = text.GetSelection();
        string detail = "words=" + found.GetText(-1) + " sel=" + selection.Length;
        if (selection.Length == 0)
        {
            // PDFium's TextPattern does not take a programmatic selection; drag the pointer across the word's box,
            // which is how a reader selects in a PDF.
            System.Windows.Rect box = found.GetBoundingRectangles().FirstOrDefault();
            detail += " rect=" + (box.IsEmpty ? "empty" : box.ToString());
            if (!box.IsEmpty) DragAcross(box);
            Thread.Sleep(400);
            selection = text.GetSelection();
            detail += " afterDrag=" + selection.Length;
        }
        return (selection.Length == 0 ? "<none>" : "<" + selection[0].GetText(-1) + ">") + " [" + detail + "]";
    }

    /// <summary>The word at `index` and its first bounding rectangle, selected so a UIA reader could read it too.</summary>
    private static (string Text, System.Windows.Rect? Rect) WordRectByUia(IntPtr window, int index)
    {
        var document = TextDocument(window);
        if (document is null) return ("<no document>", null);
        if (!document.TryGetCurrentPattern(System.Windows.Automation.TextPattern.Pattern, out object raw))
            return ("<no text pattern>", null);
        var text = (System.Windows.Automation.TextPattern)raw;
        System.Windows.Automation.Text.TextPatternRange word = text.DocumentRange.Clone();
        word.MoveEndpointByRange(System.Windows.Automation.Text.TextPatternRangeEndpoint.End,
            text.DocumentRange, System.Windows.Automation.Text.TextPatternRangeEndpoint.Start);
        word.Move(System.Windows.Automation.Text.TextUnit.Word, index);
        word.ExpandToEnclosingUnit(System.Windows.Automation.Text.TextUnit.Word);
        for (int i = 0; i < 4 && word.GetText(-1).EndsWith(' '); i++)
            word.MoveEndpointByUnit(System.Windows.Automation.Text.TextPatternRangeEndpoint.End,
                System.Windows.Automation.Text.TextUnit.Character, -1);
        word.Select();
        // **Scrolled to before its rectangles are asked for.** A word the view has scrolled out of has no rectangle
        // in the provider, and the rectangle is what the pass places the panel over (measured 2026-11-07: 'gamma'
        // was found by text and had none). A provider that needs a beat after the scroll is waited for, not assumed.
        word.ScrollIntoView(true);
        System.Windows.Rect[] boxes = [];
        for (int attempt = 0; attempt < 5 && boxes.Length == 0; attempt++)
        {
            if (attempt > 0) Thread.Sleep(100);
            boxes = word.GetBoundingRectangles();
        }
        return (word.GetText(-1), boxes.Length > 0 ? boxes[0] : null);
    }

    /// <summary>The first range whose word is `wanted`, scanned in document order; the word's index in a document with
    /// blank lines is not a number a test can rely on.</summary>
    private static (string Text, System.Windows.Rect? Rect) FindWordRectByUia(IntPtr window, string wanted)
    {
        for (int index = 0; index < 64; index++)
        {
            var found = WordRectByUia(window, index);
            if (found.Text.Trim() == wanted) return found;
        }
        // The sentinel names the failure: returning the wanted word would read as "found, no rectangle".
        return ("<" + wanted + " not found>", null);
    }

    /// <summary>The panel's own term rectangle, found through UI Automation as a reader's assistive technology would.</summary>
    private static System.Windows.Rect? PanelTermRect()
    {
        uint self = (uint)Environment.ProcessId;
        foreach (System.Windows.Automation.AutomationElement window in
                 System.Windows.Automation.AutomationElement.RootElement.FindAll(
                     System.Windows.Automation.TreeScope.Children,
                     System.Windows.Automation.Condition.TrueCondition))
        {
            if (window.Current.ProcessId != self) continue;
            var condition = new System.Windows.Automation.PropertyCondition(
                System.Windows.Automation.AutomationElement.AutomationIdProperty, "CaptureTerm");
            System.Windows.Automation.AutomationElement? term = window.FindFirst(
                System.Windows.Automation.TreeScope.Descendants, condition);
            if (term is not null && !term.Current.IsOffscreen) return term.Current.BoundingRectangle;
        }
        return null;
    }

    /// <summary>The word a document's own TextPattern range holds at a screen point, whatever window covers it.</summary>
    private static string WordAtPoint(IntPtr window, int x, int y)
    {
        var document = TextDocument(window);
        if (document is null) return "<no document>";
        if (!document.TryGetCurrentPattern(System.Windows.Automation.TextPattern.Pattern, out object raw))
            return "<no text pattern>";
        var text = (System.Windows.Automation.TextPattern)raw;
        try
        {
            System.Windows.Automation.Text.TextPatternRange word =
                text.RangeFromPoint(new System.Windows.Point(x, y));
            word.ExpandToEnclosingUnit(System.Windows.Automation.Text.TextUnit.Word);
            return word.GetText(-1).Trim();
        }
        catch (Exception error) { return "<" + error.GetType().Name + ">"; }
    }

    /// <summary>Whether the interactive desktop is locked: Windows shows the sign-in surface (LogonUI) over it, and
    /// no window can come to the foreground while it does. A GUI stage says so instead of blaming the target.</summary>
    private static bool DesktopLocked()
    {
        try
        {
            int session = Process.GetCurrentProcess().SessionId;
            return Process.GetProcessesByName("LogonUI").Any(process => process.SessionId == session);
        }
        catch (Exception) { return false; }
    }

    /// <summary>The first visible, cloaked top-level window whose box holds the point: an overlay that says it is
    /// visible while DWM shows nothing. Reported so the stage proves the skip rule was exercised, not just that the
    /// read answered — a check that cannot fail is not a check.</summary>
    private static string? CloakedAtPoint(int x, int y)
    {
        string? found = null;
        Win32.EnumWindows((window, _) =>
        {
            if (!Win32.IsWindowVisible(window) || Win32.IsIconic(window)) return true;
            if (!Win32.IsCloaked(window)) return true;
            long style = (long)Win32.GetWindowLongPtrW(window, Win32.GWL_EXSTYLE);
            if ((style & Win32.WS_EX_TRANSPARENT) != 0) return true;
            if (!Win32.GetWindowRect(window, out Win32.RECT rect)) return true;
            if (x < rect.Left || x >= rect.Right || y < rect.Top || y >= rect.Bottom) return true;
            Win32.GetWindowThreadProcessId(window, out uint pid);
            var name = new char[128];
            int length = Win32.GetClassNameW(window, name, name.Length);
            found = Win32.ProcessName(pid) + "/" + new string(name, 0, length) + "/" + window.ToInt64();
            return false;
        }, IntPtr.Zero);
        return found;
    }

    /// <summary>The windows above the target, in the order the read walks them: what a skip-rule failure is read
    /// against, since "not above the target" is otherwise a conclusion with no evidence under it.</summary>
    private static string[] AboveInventory(IntPtr target, int x, int y)
    {
        var lines = new List<string>();
        Win32.EnumWindows((window, _) =>
        {
            if (lines.Count >= 12) return false;
            if (!Win32.GetWindowRect(window, out Win32.RECT rect)) return true;
            bool atPoint = x >= rect.Left && x < rect.Right && y >= rect.Top && y < rect.Bottom;
            long style = (long)Win32.GetWindowLongPtrW(window, Win32.GWL_EXSTYLE);
            // The target closes the list and is kept: whether it is itself topmost is half of a z-order answer.
            lines.Add(DescribeWindow(window) + (window == target ? "|TARGET" : "") +
                "|visible=" + Win32.IsWindowVisible(window) +
                "|cloaked=" + Win32.IsCloaked(window) +
                "|topmost=" + ((style & Win32.WS_EX_TOPMOST) != 0) +
                "|transparent=" + ((style & Win32.WS_EX_TRANSPARENT) != 0) +
                "|atPoint=" + atPoint);
            return window != target;
        }, IntPtr.Zero);
        return lines.ToArray();
    }

    /// <summary>The first visible, cloaked window **above** the target that covers the point. A cloaked window below
    /// the target never competed for the read, so only this one proves the skip rule was exercised.</summary>
    private static string? CloakedAbove(IntPtr target, int x, int y)
    {
        string? found = null;
        Win32.EnumWindows((window, _) =>
        {
            if (window == target) return false;
            if (!Win32.IsWindowVisible(window) || Win32.IsIconic(window)) return true;
            if (!Win32.IsCloaked(window)) return true;
            long style = (long)Win32.GetWindowLongPtrW(window, Win32.GWL_EXSTYLE);
            if ((style & Win32.WS_EX_TRANSPARENT) != 0) return true;
            if (!Win32.GetWindowRect(window, out Win32.RECT rect)) return true;
            if (x < rect.Left || x >= rect.Right || y < rect.Top || y >= rect.Bottom) return true;
            Win32.GetWindowThreadProcessId(window, out uint pid);
            var name = new char[128];
            int length = Win32.GetClassNameW(window, name, name.Length);
            found = Win32.ProcessName(pid) + "/" + new string(name, 0, length) + "/" + window.ToInt64();
            return false;
        }, IntPtr.Zero);
        return found;
    }

    /// <summary>A window as one line: its process, class and handle.</summary>
    private static string? DescribeWindow(IntPtr window)
    {
        if (window == IntPtr.Zero) return null;
        Win32.GetWindowThreadProcessId(window, out uint pid);
        var name = new char[128];
        int length = Win32.GetClassNameW(window, name, name.Length);
        return Win32.ProcessName(pid) + "/" + new string(name, 0, length) + "/" + window.ToInt64();
    }

    /// <summary>The first elements of a window's tree, names and control types: what a dialog is made of.</summary>
    private static string DescribeTree(IntPtr window)
    {
        var element = System.Windows.Automation.AutomationElement.FromHandle(window);
        if (element is null) return "<no element>";
        var parts = new List<string>();
        foreach (System.Windows.Automation.AutomationElement child in
                 element.FindAll(System.Windows.Automation.TreeScope.Descendants, System.Windows.Automation.Condition.TrueCondition))
        {
            parts.Add(child.Current.ControlType.ProgrammaticName + " class=" + child.Current.ClassName + " name=" + child.Current.Name);
            if (parts.Count >= 40) break;
        }
        return string.Join(" | ", parts);
    }

    /// <summary>Closes Office's sign-in dialog through the dialog's own close button; false where none was found.</summary>
    private static bool DismissOfficeDialog(IntPtr window) => OnSta(() =>
    {
        // The dialog may be inside Word's frame or a top-level window of its own; both are searched.
        var roots = new List<IntPtr> { window };
        foreach (Process word in Process.GetProcessesByName("WINWORD"))
        {
            roots.AddRange(Win32.TopLevelWindowsOf((uint)word.Id));
            word.Dispose();
        }
        foreach (IntPtr handle in roots.Distinct())
        {
            var root = System.Windows.Automation.AutomationElement.FromHandle(handle);
            if (root is null) continue;
            var dialogs = new List<System.Windows.Automation.AutomationElement>();
            if (root.Current.Name.Contains("Office", StringComparison.Ordinal)) dialogs.Add(root);
            foreach (System.Windows.Automation.AutomationElement child in root.FindAll(
                System.Windows.Automation.TreeScope.Descendants,
                new System.Windows.Automation.PropertyCondition(
                    System.Windows.Automation.AutomationElement.ControlTypeProperty,
                    System.Windows.Automation.ControlType.Window)))
                if (child.Current.Name.Contains("Office", StringComparison.Ordinal)) dialogs.Add(child);
            foreach (System.Windows.Automation.AutomationElement dialog in dialogs)
            {
                var button = dialog.FindFirst(System.Windows.Automation.TreeScope.Descendants, CloseButton());
                if (button?.TryGetCurrentPattern(System.Windows.Automation.InvokePattern.Pattern, out object raw) == true)
                {
                    ((System.Windows.Automation.InvokePattern)raw).Invoke();
                    return true;
                }
            }
        }
        return false;
    });

    private static System.Windows.Automation.Condition CloseButton()
    {
        System.Windows.Automation.Condition named(string name) => new System.Windows.Automation.AndCondition(
            new System.Windows.Automation.PropertyCondition(
                System.Windows.Automation.AutomationElement.ControlTypeProperty,
                System.Windows.Automation.ControlType.Button),
            new System.Windows.Automation.PropertyCondition(
                System.Windows.Automation.AutomationElement.NameProperty, name));
        return new System.Windows.Automation.OrCondition(named("关闭"), named("Close"));
    }

    /// <summary>Every Document the window exposes and the first characters each holds: a viewer that answers a
    /// text pattern with no text is told apart from one whose text the lab did not select.</summary>
    private static string[] DescribeDocuments(IntPtr window)
    {
        var root = System.Windows.Automation.AutomationElement.FromHandle(window);
        if (root is null) return ["<no root>"];
        var documents = root.FindAll(System.Windows.Automation.TreeScope.Descendants,
            new System.Windows.Automation.PropertyCondition(
                System.Windows.Automation.AutomationElement.ControlTypeProperty,
                System.Windows.Automation.ControlType.Document));
        var lines = new List<string>();
        foreach (System.Windows.Automation.AutomationElement candidate in documents)
        {
            string text = "<no text pattern>";
            if (candidate.TryGetCurrentPattern(System.Windows.Automation.TextPattern.Pattern, out object raw))
                try
                {
                    text = ((System.Windows.Automation.TextPattern)raw).DocumentRange.GetText(120)
                        .Replace("\r", "\\r").Replace("\n", "\\n");
                }
                catch (Exception error) { text = "<" + error.GetType().Name + ">"; }
            lines.Add("name='" + candidate.Current.Name + "'|text='" + text + "'");
        }
        return lines.ToArray();
    }

    /// <summary>The window's **visible** text-bearing Document, not the address bar's Edit and not a hidden tab's.
    /// With `mustHold`, only a document whose text holds that word; the first visible one with text as fallback.
    /// Edge's PDF viewer exposes a hidden empty Document beside the page's, and Notepad keeps a document per tab, so
    /// a hidden one is a real candidate: its text reads fine but its rectangles place the pointer on whatever the
    /// visible document happens to draw there (measured 2026-11-07: the hover read 'beta').</summary>
    private static System.Windows.Automation.AutomationElement? TextDocument(IntPtr window, string? mustHold = null)
    {
        var root = System.Windows.Automation.AutomationElement.FromHandle(window);
        if (root is null) return null;
        var documents = root.FindAll(System.Windows.Automation.TreeScope.Descendants,
            new System.Windows.Automation.AndCondition(
                new System.Windows.Automation.PropertyCondition(
                    System.Windows.Automation.AutomationElement.IsTextPatternAvailableProperty, true),
                new System.Windows.Automation.PropertyCondition(
                    System.Windows.Automation.AutomationElement.ControlTypeProperty,
                    System.Windows.Automation.ControlType.Document)));
        System.Windows.Automation.AutomationElement? firstVisible = null, firstWithText = null;
        foreach (System.Windows.Automation.AutomationElement candidate in documents)
            if (candidate.TryGetCurrentPattern(System.Windows.Automation.TextPattern.Pattern, out object raw))
                try
                {
                    string held = ((System.Windows.Automation.TextPattern)raw).DocumentRange.GetText(4096);
                    if (held.Trim().Length == 0) continue;
                    bool holds = mustHold is null || held.Contains(mustHold, StringComparison.OrdinalIgnoreCase);
                    if (!holds) { firstWithText ??= candidate; continue; }
                    if (!candidate.Current.IsOffscreen) return candidate;
                    firstVisible ??= candidate;
                }
                catch (Exception) { }
        if (firstVisible is not null) return firstVisible;
        if (mustHold is not null) return firstWithText;
        if (documents.Count > 0) return documents[0];
        return root.FindFirst(System.Windows.Automation.TreeScope.Descendants,
            new System.Windows.Automation.PropertyCondition(
                System.Windows.Automation.AutomationElement.IsTextPatternAvailableProperty, true));
    }

    /// <summary>Presses at the box's left edge, moves across it, releases — a reader's drag over one word.</summary>
    private static void DragAcross(System.Windows.Rect box)
    {
        int left = (int)box.X + 1, right = (int)(box.X + box.Width) - 2;
        int y = (int)(box.Y + box.Height / 2);
        Win32.SetCursorPos(left, y);
        Thread.Sleep(100);
        Win32.mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); // left down
        for (int x = left + 1; x <= right; x += Math.Max(1, (right - left) / 8))
        {
            Win32.SetCursorPos(x, y);
            Thread.Sleep(20);
        }
        Win32.SetCursorPos(right, y);
        Thread.Sleep(60);
        Win32.mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); // left up
    }

    /// <summary>
    /// Focuses Notepad's document: UIA `SetFocus` on its own STA thread, then a click at its centre, retried until the
    /// focused element is the document (the WinUI menu bar holds focus first).
    /// </summary>
    /// <summary>The sentence every capture fixture is made from: the lab writes it, the .docx and PDF carry it.</summary>
    private const string FixtureSentence = "The run reader selects this sentence.";

    /// <summary>Switches to the tab whose document holds every one of `words`, then points the caret into it. Windows 11's
    /// Notepad restores its tabs, so a start page or **another run's document** can be in front (measured
    /// 2026-11-07: a restored capture-lab tab, whose first line holds the same 'run', was taken for the hover
    /// fixture). The tab is chosen by the file name the lab opened it with — not by cycling until something looks
    /// right — and a click is what gives its document the focus.</summary>
    private static string EnsureFrontDocument(IntPtr window, string fileName, params string[] words)
    {
        for (int attempt = 0; attempt < 6; attempt++)
        {
            string held = OnSta(() =>
            {
                var focused = System.Windows.Automation.AutomationElement.FocusedElement;
                if (focused is null ||
                    focused.Current.ControlType != System.Windows.Automation.ControlType.Document) return "";
                if (!focused.TryGetCurrentPattern(System.Windows.Automation.TextPattern.Pattern, out object raw))
                    return "";
                try { return ((System.Windows.Automation.TextPattern)raw).DocumentRange.GetText(4096); }
                catch (Exception) { return ""; }
            });
            // **Every** word, not one: a document holding one line of the fixture is another document's (measured
            // 2026-11-07: a tab holding only the alpha line was taken for the hover fixture).
            if (words.All(word => held.Contains(word, StringComparison.OrdinalIgnoreCase)))
                return "front after " + attempt;
            if (!OnSta(() => SelectTab(window, fileName)) && attempt > 0)
            {
                Chord(0x11, 0x09); // Ctrl+Tab: no tab of ours is named yet, so the next one may be
                Thread.Sleep(250);
            }
            ClickDocument(window);
            Thread.Sleep(250);
        }
        return "not front after 6 attempts";
    }

    /// <summary>Closes the lab's own restored tabs, keeping the file this pass opened. Windows 11's Notepad restores
    /// every tab it ever had, so a host that has run this stage a dozen times opens a dozen old fixtures in front of
    /// ours (measured 2026-11-07: seventeen tabs). Only files the lab itself wrote are touched, and each is selected
    /// through the tab strip before its close key is sent, so a tab with unsaved edits still prompts and stays.</summary>
    private static string CloseForeignTabs(IntPtr window, string keepFileName)
    {
        // One thread, one deadline: the loop is a conversation with the tab strip, and a fresh thread per step spent
        // more time starting than asking (measured 2026-11-07: a step of it timed out at the 2.5 s join).
        return OnSta(() =>
        {
            string[] ours = ["selection", "words", "word.txt", "pixels"];
            var tabCondition = new System.Windows.Automation.PropertyCondition(
                System.Windows.Automation.AutomationElement.ControlTypeProperty,
                System.Windows.Automation.ControlType.TabItem);
            int closed = 0;
            for (int round = 0; round < 32; round++)
            {
                // **A fresh root every round.** Selecting a tab rebuilds Notepad's strip, and a tree cached before
                // the change answers a later search with a stale element that never returns (measured 2026-11-07:
                // the cleanup hung).
                var root = System.Windows.Automation.AutomationElement.FromHandle(window);
                if (root is null) return "no window";
                int before = root.FindAll(System.Windows.Automation.TreeScope.Descendants, tabCondition).Count;
                System.Windows.Automation.AutomationElement? victim = null;
                foreach (System.Windows.Automation.AutomationElement tab in
                         root.FindAll(System.Windows.Automation.TreeScope.Descendants, tabCondition))
                {
                    string name = tab.Current.Name;
                    if (name.StartsWith(keepFileName, StringComparison.OrdinalIgnoreCase)) continue;
                    if (!ours.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))) continue;
                    victim = tab;
                    break;
                }
                if (victim is null) break;
                try
                {
                    ((System.Windows.Automation.SelectionItemPattern)
                        victim.GetCurrentPattern(System.Windows.Automation.SelectionItemPattern.Pattern)).Select();
                }
                catch (Exception) { break; }
                Thread.Sleep(150);
                Chord(0x11, 0x57); // Ctrl+W: Notepad's close-tab
                Thread.Sleep(300);
                var after = System.Windows.Automation.AutomationElement.FromHandle(window);
                int remaining = after is null
                    ? 0 : after.FindAll(System.Windows.Automation.TreeScope.Descendants, tabCondition).Count;
                if (remaining >= before)
                {
                    // A restored document left dirty by an earlier run prompts for its save; answering "don't save"
                    // is what lets the strip be cleaned. The lab's own fixtures are never edited by it, so the edits
                    // being discarded are a previous run's debris.
                    if (!DismissSavePrompt(window)) break; // a prompt that is not this one, or no prompt at all
                    continue;
                }
                closed++;
            }
            return closed + " tabs closed";
        }, 30000);
    }

    /// <summary>Answers Notepad's unsaved-changes prompt with "don't save", by its own button's name. The prompt is
    /// in the window's own tree (a XAML popup), so no key is sent to a dialog the lab cannot see.</summary>
    private static bool DismissSavePrompt(IntPtr window)
    {
        string[] labels = ["不保存", "Don't save", "Don’t save", "否"];
        var root = System.Windows.Automation.AutomationElement.FromHandle(window);
        if (root is null) return false;
        var button = new System.Windows.Automation.PropertyCondition(
            System.Windows.Automation.AutomationElement.ControlTypeProperty,
            System.Windows.Automation.ControlType.Button);
        foreach (System.Windows.Automation.AutomationElement candidate in
                 root.FindAll(System.Windows.Automation.TreeScope.Descendants, button))
        {
            string name = candidate.Current.Name.Trim();
            if (!labels.Any(label => name.Equals(label, StringComparison.OrdinalIgnoreCase))) continue;
            try
            {
                ((System.Windows.Automation.InvokePattern)candidate.GetCurrentPattern(
                    System.Windows.Automation.InvokePattern.Pattern)).Invoke();
                return true;
            }
            catch (Exception) { return false; }
        }
        return false;
    }

    /// <summary>Selects the tab a file was opened in, by the name the tab strip shows. False when no tab carries it
    /// yet (Notepad is still starting) or the host has no tab strip at all.</summary>
    private static bool SelectTab(IntPtr window, string fileName)
    {
        var root = System.Windows.Automation.AutomationElement.FromHandle(window);
        if (root is null) return false;
        var condition = new System.Windows.Automation.PropertyCondition(
            System.Windows.Automation.AutomationElement.ControlTypeProperty,
            System.Windows.Automation.ControlType.TabItem);
        foreach (System.Windows.Automation.AutomationElement tab in
                 root.FindAll(System.Windows.Automation.TreeScope.Descendants, condition))
        {
            if (!tab.Current.Name.Contains(fileName, StringComparison.OrdinalIgnoreCase)) continue;
            try
            {
                ((System.Windows.Automation.SelectionItemPattern)
                    tab.GetCurrentPattern(System.Windows.Automation.SelectionItemPattern.Pattern)).Select();
                return true;
            }
            catch (Exception) { return false; }
        }
        return false;
    }

    private static void ClickDocument(IntPtr window)
    {
        for (int attempt = 0; attempt < 6; attempt++)
        {
            (bool found, bool focused, double x, double y) = OnSta(() =>
            {
                var document = TextDocument(window);
                if (document is null) return (false, false, 0.0, 0.0);
                System.Windows.Rect rect = document.Current.BoundingRectangle;
                try { document.SetFocus(); } catch (Exception) { }
                bool onDocument = FocusedIsDocument();
                return (!rect.IsEmpty, onDocument, rect.X + rect.Width / 2, rect.Y + Math.Min(rect.Height / 2, 200));
            });
            if (found && x > 0 && y > 0)
            {
                Win32.SetCursorPos((int)x, (int)y);
                Thread.Sleep(80);
                Win32.mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
                Win32.mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
                Thread.Sleep(250);
            }
            bool nowFocused = OnSta(FocusedIsDocument);
            if (nowFocused) return;
            Thread.Sleep(200);
        }
    }

    /// <summary>Whether the focused element is a document; a focus that vanished between reads is not one.</summary>
    private static bool FocusedIsDocument()
    {
        try
        {
            return System.Windows.Automation.AutomationElement.FocusedElement?.Current.ControlType ==
                System.Windows.Automation.ControlType.Document;
        }
        catch (Exception) { return false; }
    }

    private static T OnSta<T>(Func<T> work, int timeoutMs = 10000)
    {
        T result = default!;
        Exception? failure = null;
        // A UIA call that throws must reach the awaiting lab as a report, never kill the process from this thread.
        var thread = new Thread(() =>
        {
            try { result = work(); }
            catch (Exception error) { failure = error; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!thread.Join(timeoutMs))
            throw new TimeoutException("the UI Automation read did not finish; later steps would overlap it");
        if (failure is not null) throw new InvalidOperationException("the UI Automation read failed: " + failure.Message, failure);
        return result;
    }

    private static Process StartNotepad(string textFile)
    {
        // Windows 11's Notepad may hand the document to another of its processes; the window is found by name below.
        Process process = Process.Start(new ProcessStartInfo("notepad.exe", "\"" + textFile + "\"") { UseShellExecute = true })!;
        return process;
    }

    private static Process? FindElevatedNotepad()
    {
        foreach (Process process in Process.GetProcessesByName("notepad"))
        {
            if (Win32.IsElevated((uint)process.Id)) return process;
            process.Dispose();
        }
        return null;
    }

    /// <summary>The visible window of any Notepad process, waiting while the app starts its tab host.</summary>
    private static IntPtr ProcessWindow(string name) => ProcessWindow(name, 15000);

    private static IntPtr NotepadWindow(int milliseconds) =>
        PollWindow(["notepad"], Win32.MainWindowOf, milliseconds);

    private static bool Focus(IntPtr window)
    {
        for (int i = 0; i < 50; i++)
        {
            if (window != IntPtr.Zero && Win32.Raise(window)) return true;
            if (window != IntPtr.Zero && Win32.GetWindowRect(window, out Win32.RECT rect))
            {
                // A shell surface (Start, search, the taskbar host) can own the foreground with no app in front, and
                // no raise call takes it from an immersive process; a click on the target's title bar does (measured
                // 2026-11-06, after a test run left ShellExperienceHost in front).
                Win32.SetCursorPos((rect.Left + rect.Right) / 2, rect.Top + 12);
                Thread.Sleep(50);
                Win32.mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); // left down
                Win32.mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); // left up
                Thread.Sleep(150);
                if (Win32.GetForegroundWindow() == window) return true;
            }
            Thread.Sleep(100);
        }
        return false;
    }

    private static async Task WriteAsync(string path, Dictionary<string, object?> report) =>
        await File.WriteAllTextAsync(path, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFontW(int height, int width, int escapement, int orientation, int weight,
        uint italic, uint underline, uint strike, uint charset, uint outPrecision, uint clipPrecision, uint quality,
        uint pitch, string face);

    [DllImport("gdi32.dll")]
    private static extern uint SetTextColor(IntPtr dc, uint colour);

    [DllImport("gdi32.dll")]
    private static extern uint SetBkColor(IntPtr dc, uint colour);

    [DllImport("gdi32.dll")]
    private static extern IntPtr GetStockObject(int index);

    /// <summary>A wordless surface for the OCR passes: a plain Win32 window that paints one word with GDI and answers
    /// Accessibility with nothing — no text pattern, no control name. A scanned page is the product case; this is its
    /// deterministic fixture, and it uses the same GDI drawing path a classic desktop app does. It is created in
    /// XDict's own process on a thread with its own message loop, so no helper binary or document format is needed.
    /// The reader's own-window branch reads it exactly as it reads any other window (Accessibility, then pixels).
    /// **The UIA-only variant** swaps the drawing for a read-only edit whose text is the word, white on white: the
    /// provider answers a text pattern, the pixels answer nothing, and a word from it can only be the UIA lane's.</summary>
    private sealed class PixelsWindow : IDisposable
    {
        public const string Face = "Arial";
        public const int Size = 96;
        public const int Width = 1200;
        public const int Height = 400;
        private const uint WsPopup = 0x80000000, WsVisible = 0x10000000;
        private const uint WsExToolWindow = 0x00000080;
        private const uint WmPaint = 0x000F, WmPrintClient = 0x0318, WmClose = 0x0010, WmDestroy = 0x0002;
        private const string ClassName = "XDictCaptureLabPixels";
        private readonly string word;
        private readonly bool unaware;
        private readonly bool uiaOnly;
        private readonly ManualResetEventSlim ready = new(false);
        private readonly Win32.WndProc proc;
        private readonly Thread thread;
        private IntPtr handle;

        public PixelsWindow(string word, bool unaware = false, bool uiaOnly = false)
        {
            this.word = word;
            this.unaware = unaware;
            this.uiaOnly = uiaOnly;
            // The delegate is held for the window's lifetime: the class registration keeps a raw pointer to it.
            proc = Window;
            thread = new Thread(Run) { IsBackground = true, Name = "capture lab pixels" };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }

        public IntPtr Handle
        {
            get { ready.Wait(10000); return handle; }
        }

        private void Run()
        {
            // A dpi-unaware window on a scaled display is the classic mixed-DPI case: the system scales its surface
            // and its thread's coordinates are not the physical ones the reader works in.
            if (unaware) Win32.SetThreadDpiAwarenessContext(Win32.DPI_AWARENESS_CONTEXT_UNAWARE);
            IntPtr instance = Win32.GetModuleHandleW(null);
            var windowClass = new Win32.WNDCLASSEX
            {
                cbSize = (uint)Marshal.SizeOf<Win32.WNDCLASSEX>(),
                style = 0x0001 | 0x0002, // CS_VREDRAW | CS_HREDRAW
                lpfnWndProc = proc,
                hInstance = instance,
                hCursor = Win32.LoadCursorW(IntPtr.Zero, (IntPtr)32512), // IDC_ARROW
                hbrBackground = (IntPtr)6, // COLOR_WINDOW + 1
                lpszClassName = ClassName,
            };
            Win32.RegisterClassExW(ref windowClass);
            handle = Win32.CreateWindowExW(WsExToolWindow, ClassName, "", WsPopup | WsVisible,
                240, 240, Width, Height, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
            // The UIA-only variant: a read-only edit whose text is the word, drawn white on white. The UIA provider
            // answers its text pattern while the pixels carry nothing, so a word from this window can only be the
            // UIA lane's.
            if (uiaOnly)
            {
                const uint child = 0x40000000, visible = 0x10000000, centre = 0x0001, multiline = 0x0004,
                    readOnlyStyle = 0x0800;
                IntPtr edit = Win32.CreateWindowExW(0, "EDIT", word, child | visible | centre | multiline | readOnlyStyle,
                    300, 140, 600, 120, handle, IntPtr.Zero, instance, IntPtr.Zero);
                IntPtr font = CreateFontW(-Size, 0, 0, 0, 700, 0, 0, 0, 1, 0, 0, 5, 0, Face);
                SendMessageW(edit, 0x0030, font, (IntPtr)1); // WM_SETFONT
            }
            // Topmost, so nothing else on screen can cover the surface the pass reads (measured 2026-11-07: a
            // browser window left by a failed pass sat over it and the read named that window). The cloaked overlay
            // is made after this one and is topmost too, so it is above it and the skip rule is exercised.
            Win32.SetWindowPos(handle, Win32.HWND_TOPMOST, 240, 240, Width, Height,
                Win32.SWP_NOACTIVATE | Win32.SWP_SHOWWINDOW);
            ready.Set();
            while (Win32.GetMessageW(out Win32.MSG message, IntPtr.Zero, 0, 0) > 0)
            {
                Win32.TranslateMessage(ref message);
                Win32.DispatchMessageW(ref message);
            }
        }

        private void Paint(IntPtr dc)
        {
            using var graphics = Graphics.FromHdc(dc);
            graphics.Clear(Color.White);
            graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using var font = new Font(Face, Size, FontStyle.Bold, GraphicsUnit.Pixel);
            // Centred, because the centre survives DPI scaling: the word's screen point is the window's centre
            // whether the window draws in physical pixels or its surface is scaled for a dpi-unaware thread.
            using var format = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center,
            };
            graphics.DrawString(word, font, Brushes.Black, new RectangleF(0, 0, Width, Height), format);
        }

        private IntPtr Window(IntPtr window, uint message, IntPtr wParam, IntPtr lParam)
        {
            switch (message)
            {
                case WmPaint:
                {
                    IntPtr dc = Win32.BeginPaint(window, out Win32.PAINTSTRUCT paint);
                    try { Paint(dc); }
                    finally { Win32.EndPaint(window, ref paint); }
                    return IntPtr.Zero;
                }
                case WmPrintClient:
                    // PrintWindow's own path: the same drawing into the caller's surface.
                    Paint(wParam);
                    return IntPtr.Zero;
                case 0x0133: // WM_CTLCOLOREDIT
                    // The edit's glyphs in white on white: UIA still holds the text; the pixels hold nothing.
                    SetTextColor(wParam, 0x00FFFFFF);
                    SetBkColor(wParam, 0x00FFFFFF);
                    return GetStockObject(0); // WHITE_BRUSH
                case WmClose:
                    Win32.DestroyWindow(window);
                    return IntPtr.Zero;
                case WmDestroy:
                    Win32.PostQuitMessage(0);
                    return IntPtr.Zero;
                default:
                    return Win32.DefWindowProcW(window, message, wParam, lParam);
            }
        }

        public void Dispose()
        {
            if (handle != IntPtr.Zero) Win32.PostMessageW(handle, WmClose, IntPtr.Zero, IntPtr.Zero);
            thread.Join(2000);
        }
    }

    /// <summary>An overlay the reader must skip: a topmost, hit-testable window that DWM cloaks, so Win32 says it is
    /// visible and nothing of it is drawn — a suspended UWP app or the shell's full-screen island. The lab makes its
    /// own because the host cannot be relied on to have one on screen (measured 2026-11-07: none above the surface,
    /// and the skip rule went unexercised). It paints a word of its own, so a reader that read it would answer that
    /// word instead of the surface's.</summary>
    private sealed class CloakedOverlay : IDisposable
    {
        private const uint WsPopup = 0x80000000, WsVisible = 0x10000000;
        private const uint WsExToolWindow = 0x00000080, WsExNoActivate = 0x08000000;
        private const uint WmDestroy = 0x0002, WmClose = 0x0010;
        private const string ClassName = "XDictCaptureLabCloak";
        private readonly ManualResetEventSlim ready = new(false);
        private readonly Win32.WndProc proc;
        private readonly Thread thread;
        private IntPtr handle;

        public string Word { get; }
        public int CloakResult { get; private set; } = -1;
        public bool Raised { get; private set; }

        public CloakedOverlay(string word, int x, int y)
        {
            Word = word;
            proc = Window;
            thread = new Thread(() => Run(x, y)) { IsBackground = true, Name = "capture lab cloak" };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }

        public IntPtr Handle
        {
            get { ready.Wait(10000); return handle; }
        }

        public bool Cloaked => handle != IntPtr.Zero && Win32.IsCloaked(handle);

        private void Run(int x, int y)
        {
            IntPtr instance = Win32.GetModuleHandleW(null);
            var windowClass = new Win32.WNDCLASSEX
            {
                cbSize = (uint)Marshal.SizeOf<Win32.WNDCLASSEX>(),
                lpfnWndProc = proc,
                hInstance = instance,
                hCursor = Win32.LoadCursorW(IntPtr.Zero, (IntPtr)32512), // IDC_ARROW
                hbrBackground = (IntPtr)6, // COLOR_WINDOW + 1
                lpszClassName = ClassName,
            };
            Win32.RegisterClassExW(ref windowClass);
            const int width = 600, height = 300;
            handle = Win32.CreateWindowExW(WsExToolWindow | WsExNoActivate, ClassName, "", WsPopup | WsVisible,
                x - width / 2, y - height / 2, width, height, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
            if (handle != IntPtr.Zero)
            {
                // Cloaked first, then raised to the top: the cloak is DWM's own attribute and arrives after the call,
                // and a window raised before it was cloaked does not stay above the surface (measured 2026-11-07:
                // the enumeration put it below, and the skip rule went unexercised). The read-back is the evidence.
                int cloak = 1;
                CloakResult = Win32.DwmSetWindowAttribute(handle, Win32.DWMWA_CLOAK, ref cloak, sizeof(int));
                for (int attempt = 0; attempt < 40 && !Win32.IsCloaked(handle); attempt++) Thread.Sleep(25);
                Raised = Win32.SetWindowPos(handle, Win32.HWND_TOPMOST, x - width / 2, y - height / 2, width, height,
                    Win32.SWP_NOACTIVATE | Win32.SWP_SHOWWINDOW);
            }
            ready.Set();
            while (Win32.GetMessageW(out Win32.MSG message, IntPtr.Zero, 0, 0) > 0)
            {
                Win32.TranslateMessage(ref message);
                Win32.DispatchMessageW(ref message);
            }
        }

        private IntPtr Window(IntPtr window, uint message, IntPtr wParam, IntPtr lParam)
        {
            switch (message)
            {
                case 0x000F: // WM_PAINT
                {
                    IntPtr dc = Win32.BeginPaint(window, out Win32.PAINTSTRUCT paint);
                    try
                    {
                        using var graphics = Graphics.FromHdc(dc);
                        graphics.Clear(Color.White);
                        using var font = new Font(PixelsWindow.Face, 40, FontStyle.Bold, GraphicsUnit.Pixel);
                        graphics.DrawString(Word, font, Brushes.Black, new PointF(20, 20));
                    }
                    finally { Win32.EndPaint(window, ref paint); }
                    return IntPtr.Zero;
                }
                case WmClose:
                    Win32.DestroyWindow(window);
                    return IntPtr.Zero;
                case WmDestroy:
                    Win32.PostQuitMessage(0);
                    return IntPtr.Zero;
                default:
                    return Win32.DefWindowProcW(window, message, wParam, lParam);
            }
        }

        public void Dispose()
        {
            if (handle != IntPtr.Zero) Win32.PostMessageW(handle, WmClose, IntPtr.Zero, IntPtr.Zero);
            thread.Join(2000);
        }
    }

    /// <summary>A one-file HTTP source on loopback: Edge opens a PDF from a URL where a file path becomes a download.</summary>
    private sealed class PdfServer : IDisposable
    {
        private readonly System.Net.Sockets.TcpListener listener;
        private readonly byte[] body;
        private readonly CancellationTokenSource stop = new();

        public string Url { get; }

        public PdfServer(string path)
        {
            body = File.ReadAllBytes(path);
            listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
            listener.Start();
            int port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
            Url = "http://127.0.0.1:" + port + "/selection.pdf";
            _ = Task.Run(ServeAsync);
        }

        private async Task ServeAsync()
        {
            while (!stop.IsCancellationRequested)
            {
                System.Net.Sockets.TcpClient client;
                try { client = await listener.AcceptTcpClientAsync(); }
                catch (Exception) { return; }
                using (client)
                {
                    try
                    {
                        System.Net.Sockets.NetworkStream stream = client.GetStream();
                        var buffer = new byte[2048];
                        _ = await stream.ReadAsync(buffer.AsMemory(0, buffer.Length), stop.Token);
                        string header = "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Disposition: inline\r\n" +
                            "Content-Length: " + body.Length + "\r\nConnection: close\r\n\r\n";
                        byte[] head = System.Text.Encoding.ASCII.GetBytes(header);
                        await stream.WriteAsync(head, stop.Token);
                        await stream.WriteAsync(body, stop.Token);
                        await stream.FlushAsync(stop.Token);
                    }
                    catch (Exception) { }
                }
            }
        }

        public void Dispose()
        {
            stop.Cancel();
            listener.Stop();
        }
    }
}
#endif
