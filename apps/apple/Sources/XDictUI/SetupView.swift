import AppKit
import SwiftUI
import XDictAnywhere
import XDictLibrary
import XDictTokens

/// **The setup window** (plan-macos-v1 WI-9): one row per `SetupBoard` step, each showing its live state and the one
/// action that completes it. Accessibility is read again every half second while the window is open, because macOS
/// posts nothing when it is granted: the row completes by itself, no relaunch.
public struct SetupView: View {
    @Bindable private var library: Library
    private let registrar: ShortcutRegistrar
    private let trusted: @MainActor () -> Bool
    private let showDictionaries: () -> Void
    @State private var isTrusted = false

    public init(library: Library, registrar: ShortcutRegistrar, trusted: @escaping @MainActor () -> Bool,
                showDictionaries: @escaping () -> Void) {
        self.library = library
        self.registrar = registrar
        self.trusted = trusted
        self.showDictionaries = showDictionaries
    }

    var board: SetupBoard {
        SetupBoard(dictionaries: library.answering.count, trusted: isTrusted, shortcutWorks: registrar.problem == nil)
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
        }
        // As tall as its rows (UI review U-01).
        .settingsPane(width: 560)
        .navigationTitle(Text("Set Up XDict"))
        .task {
            while !Task.isCancelled {
                isTrusted = trusted()
                try? await Task.sleep(for: AccessibilityGate.interval)
            }
        }
    }

    private func row(_ step: SetupBoard.Step) -> some View {
        let state = board.state(of: step)
        // A status row in a pane (R1): the step and its state lead, its action trails at regular size.
        return ActionRow {
            HStack(alignment: .top, spacing: Tokens.Space.m) {
                Image(systemName: Self.symbol(state))
                    .foregroundStyle(state == .done ? Color.green : state == .problem ? Color.red : Color.orange)
                    .font(.title2)
                    .accessibilityLabel(Self.stateName(state))
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text(SetupBoard.title(step)).font(.headline)
                    Text(board.detail(step)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            action(step, state)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.\(step.rawValue).\(Self.stateKey(state))")
    }

    @ViewBuilder
    private func action(_ step: SetupBoard.Step, _ state: SetupBoard.State) -> some View {
        switch step {
        case .dictionaries:
            // Add Dictionaries… opens the open panel itself (UI review U-02), in Settings ▸ Dictionaries (ADR-0012 d.4).
            Button {
                if state != .done { SettingsRoute.shared.requestImport() } else { showDictionaries() }
            } label: {
                Text(state == .done ? "Open Dictionary Settings" : "Add Dictionaries…")
            }
                .accessibilityIdentifier("setup.dictionaries.action")
        case .accessibility:
            if state != .done {
                Button {
                    _ = AccessibilityGate.system(true)
                    if let url = URL(string: Self.accessibilityPane) { NSWorkspace.shared.open(url) }
                } label: {
                    Text("Open System Settings")
                }
                .accessibilityIdentifier("setup.accessibility.action")
            }
        case .shortcut:
            ShortcutRecorder(registrar: registrar)
        }
    }

    static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    static func symbol(_ state: SetupBoard.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .needed: "circle.dashed"
        case .problem: "exclamationmark.triangle.fill"
        }
    }

    static func stateName(_ state: SetupBoard.State) -> LocalizedStringKey {
        switch state {
        case .done: "Done"
        case .needed: "Needed"
        case .problem: "Needs attention"
        }
    }

    /// The row's state in its identifier, for the E2E `setup` stage to read through the Accessibility tree.
    static func stateKey(_ state: SetupBoard.State) -> String {
        switch state {
        case .done: "done"
        case .needed: "needed"
        case .problem: "problem"
        }
    }
}
