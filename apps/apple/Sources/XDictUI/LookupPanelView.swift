import AppKit
import SwiftUI
import XDictAnywhere
import XDictContract
import XDictLibrary
import XDictSearch

/// What the panel shows besides an entry: the selection being read, or why nothing could be looked up.
public enum PanelNotice: Equatable, Sendable {
    case none
    case reading
    case refused(SelectionRefusal)
}

/// **The lookup panel's content** (plan-macos-v1 WI-8): the word, the dictionary whose entry is shown — a pop-up of every
/// result, grouped by dictionary, to read another — "Open in XDict" to expand into the main window, and the entry. Laid out as
/// the system Look Up popover (P41): a title row over the entry, footer rows under it (PanelLook). **The panel never takes the keyboard** (it must not
/// swallow the reader's next keystroke), so everything here is for the pointer; the keyboard has Escape, and the lookup
/// shortcut pressed again, which expands it (`help` says so).
public struct LookupPanelView: View {
    let state: SearchWindowState
    let notice: PanelNotice
    let shortcut: String?
    let expand: () -> Void
    let openLibrary: () -> Void

    public init(state: SearchWindowState, notice: PanelNotice, shortcut: String?, expand: @escaping () -> Void,
                openLibrary: @escaping () -> Void = {}) {
        self.state = state
        self.notice = notice
        self.shortcut = shortcut
        self.expand = expand
        self.openLibrary = openLibrary
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            EntryHost(controller: state.entry)
                .overlay { placeholder }
            footer
        }
        .background(PopoverMaterial())
        // The popover has no title bar: the title row starts 16 pt from the top, the hidden title bar only a drag area.
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: state.model.shown) { _, shown in
            guard let shown else { return }
            Task { await state.present(shown) }
        }
        .onChange(of: state.library.searchSources, initial: true) { state.model.sourcesDidChange() }
        .onChange(of: state.placeholder) { state.placeholderChanged() }
    }

    /// Everything around the entry, in points: the title row under its space and over its gap, and the two footer rows,
    /// each under a gap and a hairline (PanelLook).
    public static let chromeHeight: CGFloat = PanelLook.topSpace + PanelLook.titleRow + PanelLook.footerGap
        + 2 * (PanelLook.footerGap + PanelLook.footerRow + 1) + PanelLook.bottomInset

    /// The popover's title row (P41): its 20 pt title, then a rule to the trailing inset. The popover's title is the
    /// dictionary's name; XDict's keeps the speaker before the headword (owner, 2026-10-17), and the dictionary's name
    /// after the rule is the switcher of every result.
    private var header: some View {
        HStack(spacing: 8) {
            PronounceButton(state: state)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: PanelLook.titleRow, height: PanelLook.titleRow)
                .contentShape(Rectangle())
            Text(verbatim: state.shownWord ?? state.model.lookup?.query ?? "")
                .font(.system(size: PanelLook.titleSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .accessibilityIdentifier("panel.query")
            Rectangle()
                .fill(.separator)
                .frame(minWidth: 8, maxWidth: .infinity, maxHeight: 1)
                .accessibilityHidden(true)
            if state.model.sections.contains(where: { if case .results(let r) = $0.status { !r.hits.isEmpty } else { false } }) {
                ResultPicker(state: state)
                    .controlSize(.small)
            }
        }
        .frame(height: PanelLook.titleRow)
        .padding(.top, PanelLook.topSpace)
        .padding(.bottom, PanelLook.footerGap)
        .padding(.leading, PanelLook.leading)
        .padding(.trailing, PanelLook.trailing)
    }

    /// The popover's footer rows (P41): "Open in Dictionary" with a book, "Configure Dictionaries" with a gear; here
    /// "Open in XDict" and the Library.
    private var footer: some View {
        VStack(spacing: 0) {
            FooterRow(title: Text("Open in XDict"), symbol: "character.book.closed", action: expand)
                .disabled(state.model.lookup == nil)
                .help(expandHelp)
                .accessibilityIdentifier("panel.expand")
            FooterRow(title: Text("Configure Dictionaries"), symbol: "gearshape", action: openLibrary)
                .accessibilityIdentifier("panel.configure")
        }
        .padding(.bottom, PanelLook.bottomInset)
    }

    /// System Settings › Privacy & Security › Accessibility.
    static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")

    private var expandHelp: Text {
        if let shortcut { Text("Open in XDict (or press \(shortcut) again)") } else { Text("Open in XDict") }
    }

    @ViewBuilder private var placeholder: some View {
        switch notice {
        case .reading:
            ProgressView().controlSize(.small).coversPane()
        case .refused(let refusal):
            ContentUnavailableView {
                Label("Nothing to Look Up", systemImage: "text.cursor")
            } description: {
                Text(AnywhereSentences.refusal(refusal))
            } actions: {
                if refusal == .notTrusted {
                    Button("Open Accessibility Settings") { NSWorkspace.shared.open(Self.accessibilityPane) }
                        .accessibilityIdentifier("panel.openAccessibility")
                }
            }
            .coversPane()
            .accessibilityIdentifier("panel.refusal")
        case .none:
            switch state.placeholder {
            case .noDictionaries:
                ContentUnavailableView {
                    Label("No Dictionaries", systemImage: "books.vertical")
                } description: {
                    Text("XDict reads the MDict dictionaries you have. Add them, then look words up here.")
                } actions: {
                    Button("Open Library") { openLibrary() }
                }
                .coversPane()
            case .searching:
                ProgressView().controlSize(.small).coversPane()
            case .noResults(let query):
                ContentUnavailableView.search(text: query).coversPane()
            case .noResultsIncomplete(let query, let unsearched):
                NoResultsIncomplete(query: query, unsearched: unsearched, openLibrary: openLibrary).coversPane()
            case .start, .none:
                EmptyView()
            }
        }
    }
}

/// **The frosting under the popover's content** (P41, 2026-10-18): the entry is drawn on the glass with no page of its
/// own, and over a busy desktop the bare glass left the entry's text under 4.5:1 (measured 1.2–3.1 from a capture over
/// the E2E Mac's wallpaper). The system's popover material, blending what is behind the window, frosts it as Apple's
/// Look Up popover is frosted, without an opaque page.
struct PopoverMaterial: NSViewRepresentable {
    static func make() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func makeNSView(context: Context) -> NSVisualEffectView { Self.make() }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// One footer row of the popover (P41): an 8 pt gap, a hairline across the insets, then 26 pt of a semibold 13 pt title
/// 26 pt in and its symbol at the trailing inset, the whole row one button.
private struct FooterRow: View {
    let title: Text
    let symbol: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.leading, PanelLook.leading)
                .padding(.trailing, PanelLook.trailing)
                .padding(.top, PanelLook.footerGap)
            Button(action: action) {
                HStack {
                    title.font(.system(size: PanelLook.footerFontSize, weight: .semibold))
                    Spacer(minLength: 8)
                    Image(systemName: symbol).imageScale(.large).accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, PanelLook.footerLeading)
                .padding(.trailing, PanelLook.trailing)
                .frame(height: PanelLook.footerRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Every result of the panel's lookup, grouped by dictionary, the shown one checked: choosing one shows its entry.
/// Closed, it names only the dictionary read from, 80–140 pt, truncated: the headword is beside it (Codex §3).
struct ResultPicker: View {
    let state: SearchWindowState

    var body: some View {
        let sections = state.model.sections.compactMap { section -> (ResultSection, [ResultID])? in
            guard case .results(let results) = section.status, !results.hits.isEmpty else { return nil }
            return (section, results.hits.map { ResultID(dictionary: section.id, entry: $0.entry) })
        }
        Menu {
            Picker(selection: Binding(get: { state.model.selection }, set: { state.model.select($0) })) {
                ForEach(Array(sections.enumerated()), id: \.element.0.id) { index, element in
                    if index > 0 { Divider() }
                    ForEach(element.1, id: \.self) { id in
                        Text(verbatim: "\(element.0.name) — \(state.model.hit(id)?.headword ?? id.entry.key)")
                            .tag(Optional(id))
                    }
                }
            } label: {
                Text("Dictionary")
            }
            .pickerStyle(.inline)
        } label: {
            Text(verbatim: state.shownSourceName ?? "").lineLimit(1).truncationMode(.tail)
        }
        .frame(minWidth: 80, maxWidth: 140)
        .help(Text("The entry shown, and every other result"))
        .accessibilityIdentifier("panel.results")
    }
}
