// The review window: the queue, reveal-before-grade, keyboard grading, the note and its dirty close, the entry's
// availability, undo, the summary and the conflict rows. The rules are ReviewSession's; this class only maps them
// to controls and sentences. No dictionary content is stored here: the gloss is read for the card and dropped.
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using XDict.Client;
using XDict.Models;
using Windows.System;
using Windows.UI.Core;

namespace XDict.App;

public sealed partial class ReviewWindow : Window
{
    private readonly ServiceClient client;
    private readonly LibraryStore store;
    private readonly Func<string, string?> handle;
    private readonly Action<StudyCard>? openEntry;
    private readonly ReviewSession session;
    private StudyNoteDraft? draft;
    private StudyCard? shown;
    private bool busy;
    private bool askingToDiscard;
    private bool closeConfirmed;

    /// <summary>A grade, an undo or a resolution moved the next due date; the reminder plan reads it again.</summary>
    public event Action? Changed;

    public ReviewWindow(ServiceClient client, LibraryStore store, Func<string, string?> handle,
        Func<string, bool> editionAvailable, Action<StudyCard>? openEntry = null)
    {
        InitializeComponent();
        this.client = client;
        this.store = store;
        this.handle = handle;
        this.openEntry = openEntry;
        session = new ReviewSession(client, editionAvailable: editionAvailable);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)Tokens.Size.ReviewWidth, (int)Tokens.Size.ReviewHeight));
        Root.MinHeight = Tokens.Size.ReviewMinHeight;
        ThemeApplier.Apply(Root, AppSettings.Load().Theme);
        Title = Strings.Get("review.title");
        TitleText.Text = Strings.Get("review.title");
        NoteLabel.Text = Strings.Get("review.note");
        NoteBox.PlaceholderText = Strings.Get("review.notePlaceholder");
        SaveNoteButton.Content = Strings.Get("review.saveNote");
        ShowButton.Content = Strings.Get("review.showAnswer");
        AgainButton.Content = AnswerLabel("1", "review.again");
        HardButton.Content = AnswerLabel("2", "review.hard");
        GoodButton.Content = AnswerLabel("3", "review.good");
        EasyButton.Content = AnswerLabel("4", "review.easy");
        UndoButton.Content = Strings.Get("review.undo");
        OpenButton.Content = Strings.Get("review.openEntry");
        ConflictsHeading.Text = Strings.Get("review.conflicts");
        AutomationProperties.SetName(NoteBox, Strings.Get("review.note"));
        AutomationProperties.SetName(ShowButton, Strings.Get("review.showAnswer"));
        AppWindow.Closing += OnClosing;
        Root.Loaded += OnLoaded;
    }

    private static string AnswerLabel(string key, string name) =>
        Strings.Format("review.answer", key, Strings.Get(name));

    private async void OnLoaded(object sender, RoutedEventArgs e) => await GuardAsync(LoadAsync);

    private async Task GuardAsync(Func<Task> work)
    {
        try { await work(); }
        catch (Exception error) { Say(Describe(error)); }
    }

    /// <summary>The sentence is also the control's accessible name: UIA readers and the review harness read it whole.</summary>
    private void Say(string text)
    {
        StatusText.Text = text;
        AutomationProperties.SetName(StatusText, text);
    }

    private void SayNote(string text)
    {
        NoteStatus.Text = text;
        AutomationProperties.SetName(NoteStatus, text);
    }

    private async Task LoadAsync()
    {
        Say("");
        try
        {
            await session.LoadAsync();
        }
        catch (Exception error)
        {
            Say(Strings.Format("review.loadFailed", Describe(error)));
            ShowCurrent();
            return;
        }
        ShowCurrent();
        await LoadConflictsAsync();
    }

    private void ShowCurrent()
    {
        shown = session.Current;
        ShowSummary();
        if (shown is null)
        {
            draft = null;
            WordText.Text = Strings.Get("review.nothingDue");
            MetaText.Text = "";
            GlossText.Text = "";
            GlossText.Visibility = Visibility.Collapsed;
            UnavailableText.Visibility = Visibility.Collapsed;
            NoteBox.Text = "";
            NoteBox.IsEnabled = false;
            SayNote("");
            ShowButton.Visibility = Visibility.Collapsed;
            AnswerGrid.Visibility = Visibility.Collapsed;
            UndoButton.IsEnabled = false;
            OpenButton.IsEnabled = false;
            SaveNoteButton.IsEnabled = false;
            Root.Focus(FocusState.Programmatic);
            return;
        }
        draft = new StudyNoteDraft(shown);
        WordText.Text = shown.Target.EntryKey;
        MetaText.Text = DictionaryName(shown) + " · " +
            Strings.Get(shown.IsNew ? "review.new" : "review.dueCard");
        GlossText.Text = "";
        GlossText.Visibility = Visibility.Collapsed;
        bool available = session.CanOpen(shown);
        UnavailableText.Text = available ? "" : Strings.Get("review.entryUnavailable");
        UnavailableText.Visibility = available ? Visibility.Collapsed : Visibility.Visible;
        NoteBox.IsEnabled = true;
        NoteBox.Text = shown.Note.Text;
        SayNote("");
        ShowButton.Visibility = Visibility.Visible;
        ShowButton.IsEnabled = true;
        AnswerGrid.Visibility = Visibility.Collapsed;
        UndoButton.IsEnabled = session.LastGradeEvent is not null;
        OpenButton.IsEnabled = available;
        SaveNoteButton.IsEnabled = false;
        SetBusy(false);
        ShowButton.Focus(FocusState.Programmatic);
    }

    private void ShowSummary()
    {
        ReviewSummary summary = session.Summary;
        if (summary.Due == 0 && summary.NextDue is null)
        {
            SummaryText.Text = Strings.Get("review.nothingDue");
            return;
        }
        string due = Strings.Format("review.due", summary.Due);
        SummaryText.Text = summary.NextDue is { } next
            ? due + " · " + Strings.Format("review.nextDue", LocalDate(next))
            : due;
    }

    private static string LocalDate(double seconds) =>
        DateTimeOffset.FromUnixTimeSeconds((long)seconds).ToLocalTime().ToString("g");

    private string DictionaryName(StudyCard card) =>
        store.Dictionaries.FirstOrDefault(item => item.Edition == card.Target.Edition)?.DisplayName
        ?? Strings.Get("review.unknownDictionary");

    private async void OnShowAnswer(object sender, RoutedEventArgs e) => await RevealAsync();

    private async Task RevealAsync()
    {
        if (session.Current is null || session.Revealed) return;
        session.Reveal();
        ShowButton.Visibility = Visibility.Collapsed;
        AnswerGrid.Visibility = Visibility.Visible;
        AgainButton.Focus(FocusState.Programmatic);
        await LoadGlossAsync(session.Current);
    }

    private async Task LoadGlossAsync(StudyCard card)
    {
        try
        {
            HistoryGloss gloss = StudyWire.Read<HistoryGloss>(
                await client.CallAsync("entryGloss", new { entry = card.Target.EntryRef }));
            GlossText.Text = string.IsNullOrWhiteSpace(gloss.Text)
                ? Strings.Get("review.noGloss")
                : gloss.Text;
        }
        catch (Exception)
        {
            // The entry is not open here or has no usable text; the card can still be graded.
            GlossText.Text = Strings.Get("review.noGloss");
        }
        GlossText.Visibility = Visibility.Visible;
    }

    private async void OnAgain(object sender, RoutedEventArgs e) => await GradeAsync(StudyGrade.Again);
    private async void OnHard(object sender, RoutedEventArgs e) => await GradeAsync(StudyGrade.Hard);
    private async void OnGood(object sender, RoutedEventArgs e) => await GradeAsync(StudyGrade.Good);
    private async void OnEasy(object sender, RoutedEventArgs e) => await GradeAsync(StudyGrade.Easy);

    private async Task GradeAsync(StudyGrade grade)
    {
        if (busy || shown is null) return;
        if (!session.Revealed)
        {
            Say(Strings.Get("review.revealFirst"));
            return;
        }
        // The guard is taken before the first await: the note is written first, and a second grade click during that
        // write must not start a second grading operation.
        busy = true;
        SetBusy(true);
        try
        {
            if (!await SaveNoteAsync()) return;
            ReviewOutcome outcome = await session.GradeAsync(grade);
            Say(Strings.Get(outcome.Ineligible ? "review.ineligible" : "review.graded"));
            ShowCurrent();
            await LoadConflictsAsync();
            Changed?.Invoke();
        }
        catch (Exception error)
        {
            Say(Strings.Format("review.gradeFailed", Describe(error)));
        }
        finally
        {
            busy = false;
            SetBusy(false);
        }
    }

    private async void OnUndo(object sender, RoutedEventArgs e) => await UndoAsync();

    private async Task UndoAsync()
    {
        if (busy) return;
        if (session.LastGradeEvent is null)
        {
            Say(Strings.Get("review.nothingToUndo"));
            return;
        }
        busy = true;
        SetBusy(true);
        try
        {
            if (!await SaveNoteAsync()) return;
            await session.UndoAsync();
            Say(Strings.Get("review.undone"));
            ShowCurrent();
            await LoadConflictsAsync();
            Changed?.Invoke();
        }
        catch (Exception error)
        {
            Say(Strings.Format("review.undoFailed", Describe(error)));
        }
        finally
        {
            busy = false;
            SetBusy(false);
        }
    }

    private void OnNoteChanged(object sender, TextChangedEventArgs e)
    {
        if (draft is null) return;
        draft.Edit(NoteBox.Text);
        SaveNoteButton.IsEnabled = draft.IsDirty;
        SayNote(draft.IsDirty ? Strings.Get("review.noteUnsaved") : "");
    }

    private async void OnSaveNote(object sender, RoutedEventArgs e) => await SaveNoteAsync();

    /// <summary>Writes the note when it changed; false when the write failed and the caller must not move on.</summary>
    private async Task<bool> SaveNoteAsync()
    {
        if (shown is null || draft is null || !draft.IsDirty) return true;
        // The editor is closed to edits while its text is being saved: an edit typed into the TextBox after the
        // submitted snapshot would otherwise be newer than the acknowledgement and only look saved.
        NoteBox.IsReadOnly = true;
        try
        {
            await draft.SaveAsync(client, DictionaryName(shown));
            SaveNoteButton.IsEnabled = false;
            SayNote(Strings.Get("review.noteSaved"));
            return true;
        }
        catch (Exception error)
        {
            SayNote(Strings.Format("review.noteFailed", Describe(error)));
            return false;
        }
        finally
        {
            NoteBox.IsReadOnly = false;
        }
    }

    private void SetBusy(bool value)
    {
        ShowButton.IsEnabled = !value;
        AgainButton.IsEnabled = !value;
        HardButton.IsEnabled = !value;
        GoodButton.IsEnabled = !value;
        EasyButton.IsEnabled = !value;
        UndoButton.IsEnabled = !value && session.LastGradeEvent is not null;
        OpenButton.IsEnabled = !value && shown is not null && session.CanOpen(shown);
        SaveNoteButton.IsEnabled = !value && draft?.IsDirty == true;
    }

    private void OnOpenEntry(object sender, RoutedEventArgs e)
    {
        if (shown is not null) openEntry?.Invoke(shown);
    }

    private async Task LoadConflictsAsync()
    {
        ConflictRows.Children.Clear();
        IReadOnlyList<CardConflict> conflicts;
        try
        {
            conflicts = await session.ConflictsAsync();
        }
        catch (Exception error)
        {
            // A failed conflict read is not "no conflicts": an empty panel would present an unavailable list as an
            // empty one. Say the read failed; grading is unaffected.
            ConflictRows.Children.Clear();
            ConflictRows.Children.Add(new TextBlock
            {
                Text = Strings.Format("review.conflictsFailed", Describe(error)),
                TextWrapping = TextWrapping.Wrap,
            });
            ConflictsPanel.Visibility = Visibility.Visible;
            return;
        }
        ConflictsPanel.Visibility = conflicts.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        foreach (CardConflict conflict in conflicts)
        {
            var group = new StackPanel { Spacing = Tokens.Space.Xs };
            group.Children.Add(new TextBlock
            {
                Text = conflict.Target.EntryKey,
                FontSize = Tokens.Text.CardMeta,
                TextWrapping = TextWrapping.Wrap,
            });
            foreach (ConflictCandidate candidate in conflict.Candidates)
            {
                var row = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = Tokens.Space.Sm,
                };
                row.Children.Add(new TextBlock
                {
                    Text = candidate.Grade + " · " + candidate.Device + " · " + LocalDate(candidate.At),
                    FontSize = Tokens.Text.CardMeta,
                    VerticalAlignment = VerticalAlignment.Center,
                    TextWrapping = TextWrapping.Wrap,
                });
                var keep = new Button
                {
                    Content = Strings.Get("review.keep"),
                    MinWidth = Tokens.Size.ButtonMinWidth,
                };
                AutomationProperties.SetAutomationId(keep, "ReviewKeep-" + candidate.Id);
                keep.Click += async (_, _) => await ResolveAsync(conflict, candidate);
                row.Children.Add(keep);
                group.Children.Add(row);
            }
            ConflictRows.Children.Add(group);
        }
    }

    private async Task ResolveAsync(CardConflict conflict, ConflictCandidate keep)
    {
        if (busy) return;
        busy = true;
        SetBusy(true);
        try
        {
            if (!await SaveNoteAsync()) return;
            await session.ResolveAsync(conflict, keep);
            Say(Strings.Get("review.resolved"));
            ShowCurrent();
            await LoadConflictsAsync();
            Changed?.Invoke();
        }
        catch (Exception error)
        {
            Say(Strings.Format("review.resolveFailed", Describe(error)));
        }
        finally
        {
            busy = false;
            SetBusy(false);
        }
    }

    private async void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // The note editor owns its keys: Space, digits and Ctrl+Z are text there, not commands.
        if (FocusManager.GetFocusedElement(Root.XamlRoot) is TextBox) return;
        switch (e.Key)
        {
            case VirtualKey.Space:
                e.Handled = true;
                await RevealAsync();
                return;
            case VirtualKey.Number1:
            case VirtualKey.NumberPad1:
                e.Handled = true;
                await GradeAsync(StudyGrade.Again);
                return;
            case VirtualKey.Number2:
            case VirtualKey.NumberPad2:
                e.Handled = true;
                await GradeAsync(StudyGrade.Hard);
                return;
            case VirtualKey.Number3:
            case VirtualKey.NumberPad3:
                e.Handled = true;
                await GradeAsync(StudyGrade.Good);
                return;
            case VirtualKey.Number4:
            case VirtualKey.NumberPad4:
                e.Handled = true;
                await GradeAsync(StudyGrade.Easy);
                return;
            case VirtualKey.Z when InputKeyboardSource
                .GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down):
                e.Handled = true;
                await UndoAsync();
                return;
            case VirtualKey.Escape:
                e.Handled = true;
                Close();
                return;
        }
    }

    /// <summary>The process is quitting: write the note first. False when the write failed, so the caller can keep
    /// the application open rather than discard words the reader never chose to lose.</summary>
    public async Task<bool> CloseForQuitAsync()
    {
        if (draft?.IsDirty == true && !await SaveNoteAsync()) return false;
        closeConfirmed = true;
        Close();
        return true;
    }

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (closeConfirmed || draft?.IsDirty != true)
        {
            AppWindow.Closing -= OnClosing;
            return;
        }
        args.Cancel = true;
        if (askingToDiscard) return;
        askingToDiscard = true;
        _ = AskToDiscardAsync();
    }

    private async Task AskToDiscardAsync()
    {
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = Strings.Get("review.discardNote"),
                Content = Strings.Get("review.discardDetail"),
                PrimaryButtonText = Strings.Get("review.discard"),
                CloseButtonText = Strings.Get("review.keepEditing"),
            };
            ContentDialogResult result = await dialog.ShowAsync();
            if (result == ContentDialogResult.Primary)
            {
                closeConfirmed = true;
                Close();
            }
        }
        finally
        {
            askingToDiscard = false;
        }
    }

    private static string Describe(Exception error) =>
        error is ServiceFailureException failure ? ServiceMessages.For(failure.ErrorType) : error.Message;
}
