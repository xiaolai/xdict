import AppKit
import SwiftUI
import XDictAnywhere
import XDictLibrary
import XDictSpotlight
import XDictTokens

/// **What a setup row's buttons do outside the app** (plan-setup-v2 WI-2): open one of System Settings' panes, open
/// Dictionary.app, or open Settings on another pane of XDict's own. A value, so the instrument that drives the board
/// (`SetupReport`) and the tests can watch what a button would do without a window opening on anyone's screen.
public struct SetupActions: Sendable {
    /// A System Settings pane; the pane's root is the fallback when the system refuses the anchored URL.
    public var openSettings: @MainActor (SettingsLink) -> Void
    /// Dictionary.app, where macOS downloads dictionaries (ADR-0011 decision 1: XDict cannot start that download).
    public var openDictionary: @MainActor () -> Void

    public init(openSettings: @escaping @MainActor (SettingsLink) -> Void,
                openDictionary: @escaping @MainActor () -> Void) {
        self.openSettings = openSettings
        self.openDictionary = openDictionary
    }

    /// The reader's: System Settings and Dictionary.app. **Each answer falls back one step**, so a button is never
    /// inert: the anchored URL, then the pane's root, then the Settings app itself; the app by its identifier, then by
    /// the place macOS keeps it (audit-fix 2026-10-22).
    ///
    /// **Measured on macOS 27.0.1, 2026-10-22** (MacMini-010): the Accessibility and Keyboard URLs open their panes,
    /// `open -b com.apple.Dictionary` comes frontmost, and **`x-apple.systempreferences:` on its own opens no window** —
    /// which is why the last fallback is the app's own bundle. A pane this Mac does not have (Trackpad, on a Mac with no
    /// trackpad) therefore lands the reader in Settings rather than on nothing.
    public static let system = SetupActions { link in
        for url in [link.url, link.paneRoot].compactMap({ $0 }) where NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.open(URL(filePath: "/System/Applications/System Settings.app"))
    } openDictionary: {
        // The identifier resolves or it does not, and the open itself can still be refused: both fall to the place
        // macOS keeps the app, so a button is never inert.
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: dictionaryApp),
           NSWorkspace.shared.open(app) { return }
        NSWorkspace.shared.open(URL(filePath: "/System/Applications/Dictionary.app"))
    }

    /// Where macOS keeps Dictionary.app, and the bundle identifier that finds it if it moves.
    public static let dictionaryApp = "com.apple.Dictionary"
}

/// **The setup board, as a Settings pane** (plan-macos-v1 WI-9; a window of its own until 2026-10-20, ADR-0012 amended;
/// ordered, with required and optional rows, a summary and Recheck, by plan-setup-v2 WI-2): one row per `SetupBoard`
/// step, in the recommended order, each showing its live state and the one action that completes it. Accessibility is
/// read again every half second while the pane is up, because macOS posts nothing when it is granted: the row completes
/// by itself, no relaunch. The system's own preferences (`SystemProbes`) are read when the pane appears and again on
/// **Recheck** — never every half second: they cost four domain reads and change only when the reader changes them.
public struct SetupView: View {
    @Bindable private var library: Library
    private let registrar: ShortcutRegistrar
    private let trusted: @MainActor () -> Bool
    private let showDictionaries: () -> Void
    /// Hover, when this run has one: nil in a window an instrument draws on its own, where the row says off.
    private let hover: HoverControl?
    /// The reader's Spotlight switch (plan-setup-v2 WI-6; ADR-0028), when this build has one.
    private let spotlight: SpotlightSettings?
    /// Whether a meaning source is set up, as Settings ▸ AI reads it (plan-setup-v2 WI-7).
    private let aiConfigured: @MainActor () -> Bool
    /// What the app does when the reader changes the switch: index the library, or delete every XDict domain.
    private let onSpotlight: (@MainActor (Bool) -> Void)?
    private let probes: SystemProbes
    private let actions: SetupActions
    @State private var isTrusted = false
    @State private var reading = SystemProbes.Reading(services: .unreadable, appleLookUp: AppleLookUp())
    @State private var aiIsOn = false
    /// Which recheck's answer is the one to keep: Recheck pressed twice, or the pane appearing while a read is in
    /// flight, must not let an older read land last (audit-fix 2026-10-22).
    @State private var probeGeneration = 0
    /// Bumped by Recheck; `.task(id:)` owns the read, so closing the pane cancels it with the view (audit-fix 2026-10-22).
    @State private var recheckCount = 0

    public init(library: Library, registrar: ShortcutRegistrar, trusted: @escaping @MainActor () -> Bool,
                showDictionaries: @escaping () -> Void, hover: HoverControl? = nil,
                spotlight: SpotlightSettings? = nil,
                aiConfigured: @escaping @MainActor () -> Bool = { false },
                onSpotlight: (@MainActor (Bool) -> Void)? = nil,
                probes: SystemProbes = .live, actions: SetupActions = .system) {
        self.library = library
        self.registrar = registrar
        self.trusted = trusted
        self.showDictionaries = showDictionaries
        self.hover = hover
        self.spotlight = spotlight
        self.aiConfigured = aiConfigured
        self.onSpotlight = onSpotlight
        self.probes = probes
        self.actions = actions
    }

    var board: SetupBoard {
        // **Registration is the fact, not the last refusal** (audit-fix 2026-10-22): a refused *replacement* leaves the
        // old shortcut registered and still sets `problem`, and the recorder is the one that words that; while the
        // recorder is armed the hot key is suspended on purpose, which is not a failure either.
        SetupBoard(dictionaries: library.answering.count, trusted: isTrusted,
                   shortcutWorks: registrar.isRegistered || registrar.isSuspended,
                   hoverOn: hover?.isOn ?? false, hoverKey: hover?.keySymbol ?? "⌥",
                   hoverDoubleTap: hover?.isDoubleTap ?? false, screenRecording: hover?.screenRecording ?? .notSetUp,
                   services: reading.services, appleLookUp: reading.appleLookUp,
                   spotlightEnabled: spotlight?.enabled ?? false, spotlightFailed: spotlight?.lastRunFailed ?? false,
                   aiConfigured: aiIsOn)
    }

    public var body: some View {
        Form {
            Section {
                ForEach(SetupBoard.Step.allCases) { step in
                    row(step)
                }
            } header: {
                Text("XDict looks words up in your own MDict dictionaries. Each row below shows what is set up now.")
                    .font(.callout)
            }
            Section {
                summary
            }
        }
        // As tall as its rows, at the one width every pane shares (UI review U-01; ADR-0012 d.6).
        .settingsPane()
        .task {
            while !Task.isCancelled {
                isTrusted = trusted()
                try? await Task.sleep(for: AccessibilityGate.interval)
            }
        }
        .task(id: recheckCount) { await recheck() }
    }

    private func row(_ step: SetupBoard.Step) -> some View {
        let state = board.state(of: step)
        // A status row in a pane (R1): the step and its state lead, its actions trail at regular size.
        return ActionRow {
            HStack(alignment: .top, spacing: Tokens.Space.m) {
                Image(systemName: Self.symbol(state))
                    .foregroundStyle(Self.color(state))
                    .font(.title2)
                    .accessibilityLabel(Self.stateName(state))
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text(SetupBoard.title(step)).font(.headline)
                    Text(board.detail(step)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if step == .appleLookUp { parts }
                }
            }
        } actions: {
            switch step {
            case .dictionaries:
                // **One control, two sources** (UI tour 2026-10-22: two regular buttons beside the sentence squeezed it
                // into a one-word column): Apple's own Dictionaries pane offers its ways to add behind one menu (P39).
                // The label's own click is the usual one, and both routes keep their identifiers for the AX tree.
                Menu {
                    // Add MDX… opens the open panel itself (UI review U-02), in Settings ▸ Dictionaries (ADR-0012 d.4).
                    Button { SettingsRoute.shared.requestImport() } label: { Text("Add MDX Files…") }
                        .accessibilityIdentifier("setup.dictionaries.action")
                    // The Apple import lives in Settings ▸ Dictionaries' one presentation (ADR-0012 d.3).
                    Button { SettingsRoute.shared.requestAppleImport() } label: { Text("Add Apple Dictionaries…") }
                        .accessibilityIdentifier("setup.dictionaries.apple")
                } label: {
                    Text(state == .done ? "Open Dictionary Settings" : "Add Dictionaries…")
                } primaryAction: {
                    if state == .done { showDictionaries() } else { SettingsRoute.shared.requestImport() }
                }
                .accessibilityIdentifier("setup.dictionaries.action")
            case .accessibility:
                if state != .done {
                    Button { actions.openSettings(.accessibility) } label: { Text("Open System Settings") }
                        .accessibilityIdentifier("setup.accessibility.action")
                }
            case .screenRecording:
                // **The board's own place to grant it** (owner, 2026-10-23): the same two actions as the hover pane's
                // row, through the one `ScreenRecordingAccess` — `Allow…` is the only call that can prompt.
                if let hover {
                    Group {
                        switch hover.screenRecording {
                        case .notSetUp:
                            Button { Task { await hover.setUpScreenRecording() } } label: { Text("Allow…") }
                                .accessibilityIdentifier("setup.screenRecording.allow")
                        case .allowed:
                            EmptyView()
                        case .notAllowed, .couldNotTell:
                            Button { Task { await hover.refreshScreenRecording() } } label: { Text("Check Again") }
                                .accessibilityIdentifier("setup.screenRecording.check")
                        }
                    }
                    // **Read, never ask**: showing the row reads the standing grant without calling anything that could
                    // prompt (`ScreenRecordingAccess`); the button is the only thing that asks.
                    .task { await hover.refreshScreenRecording() }
                }
            case .shortcut:
                ShortcutRecorder(registrar: registrar)
            case .hover:
                if let hover {
                    Toggle(isOn: Binding(get: { hover.isOn }, set: { hover.setEnabled($0) })) { Text("Hover") }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("setup.hover.toggle")
                }
                Button { SettingsRoute.shared.showPane(.general) } label: { Text("Open General") }
                    .accessibilityIdentifier("setup.hover.general")
            case .services:
                Button { actions.openSettings(.keyboardShortcuts) } label: { Text("Open Keyboard Shortcuts") }
                    .accessibilityIdentifier("setup.services.open")
            case .appleLookUp:
                // Nothing trails the row: each of its three lines carries the button for the pane it names (see `parts`).
                EmptyView()
            case .spotlight:
                if let spotlight {
                    Toggle(isOn: Binding(get: { spotlight.enabled }, set: { on in
                        // **The switch is the index's order**: turning it on indexes, turning it off deletes every
                        // XDict domain (ADR-0028 decision 3) — the app does that work, the settings only record it.
                        _ = spotlight.setEnabled(on)
                        onSpotlight?(spotlight.enabled)
                    })) {
                        Text("Include in Spotlight")
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("setup.spotlight.toggle")
                }
                if spotlight?.lastRunFailed == true {
                    Text("Spotlight could not be updated. Turn this off and on to try again.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { actions.openSettings(.spotlight) } label: { Text("Open Spotlight Settings") }
                    .accessibilityIdentifier("setup.spotlight.open")
            case .ai:
                Button { SettingsRoute.shared.showPane(.ai) } label: { Text("Open AI Settings") }
                    .accessibilityIdentifier("setup.ai.open")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.\(step.rawValue).\(Self.stateKey(state))")
    }

    /// **Apple's three triggers, one row line each**, so a reader told "something is on" can see what and where to turn
    /// it off — and the line's own button opens the pane that line names (UI tour 2026-10-22: three regular buttons in
    /// the row's trailing group left the sentences a column one word wide; R2 puts a small control on the line it is
    /// about). **A line whose fact was not read says only what it is**: the row above it already says "Check this in
    /// System Settings", and three copies of that sentence say nothing more.
    @ViewBuilder private var parts: some View {
        ForEach(AppleLookUp.Part.allCases, id: \.self) { part in
            let fact = board.appleLookUp.fact(part)
            ActionRow(.strip) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
                    Image(systemName: fact == .ready ? "checkmark.circle" : "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(fact == .ready ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                    // The label over its sentence, never concatenated: a joined string would be a catalog key of its
                    // own ("%@: %@"), and `Text + Text` is deprecated from macOS 26.
                    VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                        Text(SetupBoard.appleLookUpTitle(part)).font(.callout)
                        if fact != .unreadable {
                            Text(board.appleLookUpDetail(part)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } actions: {
                Button { open(part) } label: { Text(Self.linkTitle(part)) }
            }
            // A line of the row, not the row: the row's own id carries its state, and these three carry which trigger.
            .accessibilityIdentifier("setup.appleLookUp.part.\(part.rawValue)")
        }
    }

    /// The pane each line's button opens.
    private func open(_ part: AppleLookUp.Part) {
        switch part {
        case .shortcut: actions.openSettings(.keyboardShortcuts)
        case .trackpad: actions.openSettings(.trackpad)
        case .dictionaries: actions.openDictionary()
        }
    }

    static func linkTitle(_ part: AppleLookUp.Part) -> LocalizedStringResource {
        switch part {
        case .shortcut: LocalizedStringResource("Keyboard Shortcuts")
        case .trackpad: LocalizedStringResource("Trackpad")
        case .dictionaries: LocalizedStringResource("Dictionary")
        }
    }

    /// **What is verified, what still needs the reader, and what is optional and left** (plan-setup-v2 WI-2, WI-7).
    private var summary: some View {
        let boardSummary = board.summary
        let headline = boardSummary.needsUser.isEmpty
            ? LocalizedStringResource("XDict is set up.")
            : LocalizedStringResource("Still needs you: \(Self.names(boardSummary.needsUser)).")
        return ActionRow {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(headline).font(.headline)
                if !boardSummary.verified.isEmpty {
                    Text("Verified: \(Self.names(boardSummary.verified)).").foregroundStyle(.secondary)
                }
                if !boardSummary.optionalLeft.isEmpty {
                    Text("Optional, not set up: \(Self.names(boardSummary.optionalLeft)).").foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button { recheckCount += 1 } label: { Text("Recheck") }
                .accessibilityIdentifier("setup.recheck")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.summary")
    }

    /// **Read the system's own preferences again** — on appear, and when the reader presses Recheck. Off the main
    /// actor: four domains, each read whole.
    private func recheck() async {
        probeGeneration += 1
        let mine = probeGeneration
        let probes = probes
        let read = await Task.detached(priority: .userInitiated) { probes.read() }.value
        // A newer recheck's answer wins, and an answer that arrives after the pane closed is not published at all.
        guard mine == probeGeneration, !Task.isCancelled else { return }
        reading = read
        aiIsOn = aiConfigured()
    }

    /// Steps by name, joined the way the reader's language joins a list ("A and B", "A、B和C").
    static func names(_ steps: [SetupBoard.Step]) -> String {
        steps.map { String(localized: SetupBoard.title($0)) }.formatted(.list(type: .and))
    }

    static func symbol(_ state: SetupBoard.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .needed: "circle.dashed"
        case .problem: "exclamationmark.triangle.fill"
        case .needsCheck: "questionmark.circle"
        case .optional: "circle.dashed"
        }
    }

    static func color(_ state: SetupBoard.State) -> Color {
        switch state {
        case .done: .green
        case .needed: .orange
        case .problem: .red
        case .needsCheck, .optional: .secondary
        }
    }

    static func stateName(_ state: SetupBoard.State) -> LocalizedStringKey {
        switch state {
        case .done: "Done"
        case .needed: "Needed"
        case .problem: "Needs attention"
        case .needsCheck: "Needs a check"
        case .optional: "Optional"
        }
    }

    /// The row's state in its identifier, for the E2E `setup` stage to read through the Accessibility tree.
    static func stateKey(_ state: SetupBoard.State) -> String {
        switch state {
        case .done: "done"
        case .needed: "needed"
        case .problem: "problem"
        case .needsCheck: "needsCheck"
        case .optional: "optional"
        }
    }
}
