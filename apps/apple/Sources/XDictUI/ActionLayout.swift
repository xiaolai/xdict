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
// - R6 Apple's own measured layouts keep their places: the toolbar (P3), menus, the Settings table's +/− (P39) and the
//   popover's footer rows (P41).

/// Where a group of actions sits, which decides their size (R4).
enum ActionSurface: Equatable {
    /// A pane: Settings, a sheet's form, a notice of its own (R1, R5).
    case pane
    /// A list row or a strip: the notices strip, a progress row, a row of a sheet's list (R2).
    case strip
    /// A sheet's or a dialog's footer (R3).
    case footer

    var controlSize: ControlSize {
        switch self {
        case .pane, .footer: .regular
        case .strip: .small
        }
    }
}

/// The places of a sheet's footer, in reading order (R3).
enum FooterSlot: CaseIterable, Equatable {
    case destructive, cancel, primary

    /// Escape for Cancel, Return for the default action; nothing for a destructive one, which is never the default.
    var keyEquivalent: KeyboardShortcut? {
        switch self {
        case .destructive: nil
        case .cancel: .cancelAction
        case .primary: .defaultAction
        }
    }

    /// The destructive action sits at the leading edge, apart from the others at the trailing one.
    var standsApart: Bool { self == .destructive }
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
/// trailing one, Escape and Return theirs. A slot left empty takes no room.
struct SheetFooter<Destructive: View, Cancel: View, Primary: View>: View {
    @ViewBuilder let destructive: Destructive
    @ViewBuilder let cancel: Cancel
    @ViewBuilder let primary: Primary

    init(@ViewBuilder destructive: () -> Destructive, @ViewBuilder cancel: () -> Cancel,
         @ViewBuilder primary: () -> Primary) {
        self.destructive = destructive()
        self.cancel = cancel()
        self.primary = primary()
    }

    var body: some View {
        HStack(spacing: Tokens.Space.sm) {
            destructive.keyboardShortcut(FooterSlot.destructive.keyEquivalent)
            Spacer()
            cancel.keyboardShortcut(FooterSlot.cancel.keyEquivalent)
            primary.keyboardShortcut(FooterSlot.primary.keyEquivalent)
        }
        .controlSize(ActionSurface.footer.controlSize)
    }
}

extension SheetFooter where Destructive == EmptyView {
    /// Cancel and the default action.
    init(@ViewBuilder cancel: () -> Cancel, @ViewBuilder primary: () -> Primary) {
        self.init(destructive: { EmptyView() }, cancel: cancel, primary: primary)
    }
}

extension SheetFooter where Cancel == EmptyView {
    /// A destructive action and the default action, with nothing to cancel.
    init(@ViewBuilder destructive: () -> Destructive, @ViewBuilder primary: () -> Primary) {
        self.init(destructive: destructive, cancel: { EmptyView() }, primary: primary)
    }
}
