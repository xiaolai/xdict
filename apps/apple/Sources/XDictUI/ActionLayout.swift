import SwiftUI
import XDictTokens

// **Where a button goes, in one place** (owner, 2026-10-18: one set of rules for every button of the shell, from Apple's
// HIG conventions; `ButtonPlacementTests` fails a button placed or sized by hand anywhere else):
//
// - R1 A status or problem row in a pane, and a question with its answers: the sentence leads and takes the width; its
//   actions are one trailing group at regular size, the primary action rightmost, a second one left of it (`ActionRow`).
// - R2 A control in a list row or a strip: small, at the trailing edge, at its own width so a bar or a long sentence
//   never squeezes it (`ActionRow(.strip)`, `TrailingActions(.strip)`); a progress row is its sentence over a bar that
//   takes the width, the control beside the bar (`ProgressRow`).
// - R3 A sheet's footer: trailing, Cancel left of the default action, Escape and Return theirs; only the default action
//   is prominent; a destructive action is never the default and stands apart at the leading edge (`SheetFooter`).
// - R4 One surface, one size: the surface decides it, never the site (`ActionSurface`).
// - R5 A single action in an otherwise-text row goes trailing (`ActionRow`).
// - An empty state's ways on sit centred under its sentence, the first prominent when a second is under it
//   (`EmptyStateActions`).
// - R6 Apple's own measured layouts keep their places, each site marked `// placement: <id>` on its line:
//   the toolbar (P3) and its speaker (P48); the menus: app (P31), File (P32), Edit ▸ Find (P33), View (P34), Go (P35),
//   Search (P36), Help (P38), and the menu-bar item's menu; the scope bar (P6); the find bar (P30); Settings ▸
//   Dictionaries' table checkboxes and +/− (P39); the lookup popover's speaker and footer rows (P41). The system's own:
//   an NSAlert (it already follows R3), a spinner, an icon-only glyph, the shortcut recorder and a Form's
//   LabeledContent. `ButtonPlacementTests.exclusions` is the list of ids, each with why; an unknown or unused id fails.

/// Where a group of actions sits, which decides their size (R4).
enum ActionSurface: Equatable {
    /// A pane: Settings, a sheet's form, a notice of its own (R1, R5).
    case pane
    /// A list row or a strip: the notices strip, a progress row, a row of a sheet's list (R2).
    case strip
    /// A sheet's or a dialog's footer (R3).
    case footer
    /// An empty state: its ways on, centred under its sentence.
    case emptyState

    var controlSize: ControlSize {
        switch self {
        case .pane, .footer, .emptyState: .regular
        case .strip: .small
        }
    }
}

/// What a sheet's footer lays out, in reading order (R3). `SheetFooter`'s body draws exactly `arrangement`.
enum FooterItem: Hashable {
    /// The destructive action, at the leading edge.
    case destructive
    /// The space that sets it apart from the rest, at the trailing edge.
    case gap
    case cancel
    /// No Cancel to take Escape (a sheet whose changes apply at once): Escape closes the sheet, as Done does.
    case closeOnEscape
    /// The default action, rightmost.
    case primary

    /// Escape for Cancel or for closing, Return for the default action; nothing for a destructive one, which is never
    /// the default.
    var keyEquivalent: KeyboardShortcut? {
        switch self {
        case .destructive, .gap: nil
        case .cancel, .closeOnEscape: .cancelAction
        case .primary: .defaultAction
        }
    }

    static func arrangement(closesOnEscape: Bool) -> [FooterItem] {
        [.destructive, .gap, closesOnEscape ? .closeOnEscape : .cancel, .primary]
    }
}

/// An empty state's ways on, top to bottom: the first, then the one under it.
enum EmptyStateItem: Hashable {
    case primary, secondary

    static func arrangement(hasSecondary: Bool) -> [EmptyStateItem] { hasSecondary ? [.primary, .secondary] : [.primary] }

    /// The first way on is prominent only when it is one of two: a single one is the page's only button anyway.
    func isProminent(hasSecondary: Bool) -> Bool { self == .primary && hasSecondary }
}

/// What a progress row's bar shows (R2).
enum ProgressBar: Equatable {
    /// No bar: the sentence says where it is.
    case none
    /// A bar that moves, how far not yet known.
    case indeterminate
    /// How far, from none to all.
    case fraction(Double)

    /// A count of a total; none when there is no total to count against.
    static func of<Count: BinaryInteger>(done: Count, total: Count) -> ProgressBar {
        guard total > 0 else { return .none }
        return .fraction(min(max(Double(done) / Double(total), 0), 1))
    }

    /// A fraction the service reported, or a moving bar until it does.
    static func of(fraction: Double?) -> ProgressBar {
        guard let fraction else { return .indeterminate }
        return .fraction(min(max(fraction, 0), 1))
    }
}

/// One group of actions at the trailing edge, at its surface's size and its own width (R1, R2, R4).
struct TrailingActions<Actions: View>: View {
    let surface: ActionSurface
    @ViewBuilder let actions: Actions

    init(_ surface: ActionSurface, @ViewBuilder actions: () -> Actions) {
        self.surface = surface
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: Tokens.Space.sm) { actions }
            .controlSize(surface.controlSize)
            .fixedSize()
            .layoutPriority(1)
    }
}

/// A sentence and its actions (R1, R2, R5): the sentence leads and takes the width, wrapping; the actions trail, at the
/// surface's size, never squeezed. Two answers: the primary one last.
struct ActionRow<Sentence: View, Actions: View>: View {
    let surface: ActionSurface
    @ViewBuilder let sentence: Sentence
    @ViewBuilder let actions: Actions

    init(_ surface: ActionSurface = .pane, @ViewBuilder sentence: () -> Sentence, @ViewBuilder actions: () -> Actions) {
        self.surface = surface
        self.sentence = sentence()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.sm) {
            sentence.frame(maxWidth: .infinity, alignment: .leading)
            TrailingActions(surface) { actions }
        }
    }
}

extension ActionRow {
    /// A question and its two answers (R1): the secondary one left of the primary, which is rightmost.
    init<Secondary: View, Primary: View>(_ surface: ActionSurface = .pane, @ViewBuilder sentence: () -> Sentence,
                                         @ViewBuilder secondary: () -> Secondary, @ViewBuilder primary: () -> Primary)
    where Actions == TupleView<(Secondary, Primary)> {
        self.init(surface, sentence: sentence) {
            secondary()
            primary()
        }
    }
}

/// A row of work under way (R2): its sentence, then the bar taking the width with the control beside it at its own
/// small size. With no bar, the sentence takes the width and the control trails it.
struct ProgressRow<Sentence: View, Control: View>: View {
    let bar: ProgressBar
    @ViewBuilder let sentence: Sentence
    @ViewBuilder let control: Control

    init(bar: ProgressBar, @ViewBuilder sentence: () -> Sentence, @ViewBuilder control: () -> Control) {
        self.bar = bar
        self.sentence = sentence()
        self.control = control()
    }

    var body: some View {
        switch bar {
        case .none:
            ActionRow(.strip, sentence: { sentence }, actions: { control })
        case .indeterminate, .fraction:
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                sentence
                HStack(spacing: Tokens.Space.sm) {
                    ProgressBarView(bar: bar).frame(maxWidth: .infinity)
                    TrailingActions(.strip) { control }
                }
            }
        }
    }
}

/// A progress row's bar, taking the width it is given (R2); nothing for `.none`.
struct ProgressBarView: View {
    let bar: ProgressBar

    var body: some View {
        switch bar {
        case .none: EmptyView()
        case .indeterminate: ProgressView().progressViewStyle(.linear)
        case .fraction(let fraction): ProgressView(value: fraction)
        }
    }
}

/// A sheet's footer (R3): a destructive action apart at the leading edge, then Cancel and the default action at the
/// trailing one, Escape and Return theirs, in `FooterItem.arrangement`'s order. A slot left empty takes no room. With
/// nothing to cancel, Escape closes the sheet.
struct SheetFooter<Destructive: View, Cancel: View, Primary: View>: View {
    @ViewBuilder let destructive: Destructive
    @ViewBuilder let cancel: Cancel
    @ViewBuilder let primary: Primary
    let closeOnEscape: (() -> Void)?

    init(@ViewBuilder destructive: () -> Destructive, @ViewBuilder cancel: () -> Cancel,
         @ViewBuilder primary: () -> Primary) {
        self.init(destructive: destructive(), cancel: cancel(), primary: primary(), closeOnEscape: nil)
    }

    fileprivate init(destructive: Destructive, cancel: Cancel, primary: Primary, closeOnEscape: (() -> Void)?) {
        self.destructive = destructive
        self.cancel = cancel
        self.primary = primary
        self.closeOnEscape = closeOnEscape
    }

    /// What this footer lays out, in order: its body draws exactly this.
    var arrangement: [FooterItem] { FooterItem.arrangement(closesOnEscape: closeOnEscape != nil) }

    var body: some View {
        HStack(spacing: Tokens.Space.sm) {
            ForEach(arrangement, id: \.self) { item in
                switch item {
                case .destructive: destructive.keyboardShortcut(item.keyEquivalent)
                case .gap: Spacer()
                case .cancel: cancel.keyboardShortcut(item.keyEquivalent)
                case .closeOnEscape:
                    if let closeOnEscape {
                        // Escape's own key, with no room, picture or VoiceOver element of its own: Done says the same.
                        Button(action: closeOnEscape) { EmptyView() }
                            .buttonStyle(.plain)
                            .frame(width: 0, height: 0)
                            .opacity(0)
                            .accessibilityHidden(true)
                            .keyboardShortcut(item.keyEquivalent)
                    }
                case .primary: primary.keyboardShortcut(item.keyEquivalent)
                }
            }
        }
        .controlSize(ActionSurface.footer.controlSize)
    }
}

extension SheetFooter where Destructive == EmptyView {
    /// Cancel and the default action.
    init(@ViewBuilder cancel: () -> Cancel, @ViewBuilder primary: () -> Primary) {
        self.init(destructive: EmptyView(), cancel: cancel(), primary: primary(), closeOnEscape: nil)
    }
}

extension SheetFooter where Cancel == EmptyView {
    /// A destructive action and the default action, with nothing to cancel: Escape closes the sheet.
    init(@ViewBuilder destructive: () -> Destructive, @ViewBuilder primary: () -> Primary,
         closeOnEscape: @escaping () -> Void) {
        self.init(destructive: destructive(), cancel: EmptyView(), primary: primary(), closeOnEscape: closeOnEscape)
    }
}

/// An empty state's ways on (`ActionSurface.emptyState`), centred under its sentence: in a `ContentUnavailableView`'s
/// actions or a page of its own. The first is prominent when a second sits under it (`EmptyStateItem`).
struct EmptyStateActions<Primary: View, Secondary: View>: View {
    @ViewBuilder let primary: Primary
    @ViewBuilder let secondary: Secondary
    let hasSecondary: Bool

    init(@ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
        self.primary = primary()
        self.secondary = secondary()
        hasSecondary = true
    }

    var body: some View {
        VStack(spacing: Tokens.Space.sm) {
            ForEach(EmptyStateItem.arrangement(hasSecondary: hasSecondary), id: \.self) { item in
                switch item {
                case .primary:
                    if item.isProminent(hasSecondary: hasSecondary) {
                        primary.buttonStyle(.borderedProminent)
                    } else {
                        primary
                    }
                case .secondary: secondary
                }
            }
        }
        .controlSize(ActionSurface.emptyState.controlSize)
    }
}

extension EmptyStateActions where Secondary == EmptyView {
    /// One way on.
    init(@ViewBuilder primary: () -> Primary) {
        self.primary = primary()
        secondary = EmptyView()
        hasSecondary = false
    }
}
