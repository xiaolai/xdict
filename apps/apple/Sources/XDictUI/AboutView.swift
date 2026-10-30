import AppKit
import SwiftUI
import XDictTokens

/// **About XDict** (owner, 2026-10-29): the window the app menu opens, and Settings' last pane, from one view so the two
/// cannot drift. It says what this copy is, what it is licensed under, where its source and site are, and — on a tap, and
/// never before — whether GitHub lists a newer release.
///
/// **AppKit here is the app icon and nothing else**: SwiftUI has no API for an application's own icon
/// (`NSImage.applicationIconName`), which is the one thing the panel shows that is not text or a control.
public struct AboutView: View {
    /// Opens the Acknowledgments window, which belongs to the app: the view asks; it does not know window ids.
    private let acknowledge: () -> Void
    @State private var model = AboutModel()

    public init(acknowledge: @escaping () -> Void = {}) {
        self.acknowledge = acknowledge
    }

    public var body: some View {
        Form {
            Section {
                HStack(spacing: Tokens.Space.l) {
                    Image(nsImage: Self.icon)
                        .resizable()
                        .frame(width: Tokens.Window.aboutIconSize, height: Tokens.Window.aboutIconSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                        Text(verbatim: "XDict").font(.title2.bold())
                        Text(verbatim: Self.versionLine(model.version, model.build))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, Tokens.Space.xs)
            }

            Section {
                LabeledContent { Text(verbatim: model.version).textSelection(.enabled) } label: { Text("Version") }
                LabeledContent { Text(verbatim: model.build).textSelection(.enabled) } label: { Text("Build") }
                LabeledContent { Text(verbatim: ProcessInfo.processInfo.operatingSystemVersionString)
                    .textSelection(.enabled) } label: { Text("macOS") }
                LabeledContent { Text("ISC") } label: { Text("Licence") }
            } header: {
                Text("This copy")
            }
            .settingsAnchor(.about)

            Section {
                update
            } header: {
                Text("Updates")
            }

            Section {
                Link(destination: Self.site) { Text("XDict Website") }  // placement: form-pane
                Link(destination: Self.repository) { Text("Source Code") }  // placement: form-pane
                Button { acknowledge() } label: { Text("Acknowledgments") }  // placement: form-pane
            } header: {
                Text("XDict is free software.")
            }
        }
        .formStyle(.grouped)
    }

    /// The reader's tap, and the one request this app makes about itself.
    @ViewBuilder private var update: some View {
        switch model.update {
        case .notAsked:
            Button { Task { await model.check() } } label: { Text("Check for Updates…") }  // placement: form-pane
                .accessibilityIdentifier("about.check-for-updates")
        case .checking:
            HStack(spacing: Tokens.Space.sm) {
                ProgressView().controlSize(.small)  // placement: spinner
                Text("Asking GitHub for the latest release…")
            }
        case .current(let latest):
            Label { Text("This is the newest release (\(latest)).") } icon: { Image(systemName: "checkmark.circle") }
            Button { Task { await model.check() } } label: { Text("Check Again") }  // placement: form-pane
        case .available(let latest, let page):
            Label { Text("Version \(latest) is available.") } icon: { Image(systemName: "arrow.down.circle") }
            Link(destination: page) { Text("Read the Release Notes") }  // placement: form-pane
        case .failed:
            Label { Text("XDict could not check for updates.") } icon: { Image(systemName: "exclamationmark.triangle") }
            Button { Task { await model.check() } } label: { Text("Try Again") }  // placement: form-pane
        }
    }

    public static let site = URL(string: "https://xdict.ai")!
    public static let repository = URL(string: "https://github.com/xiaolai/xdict")!

    /// "0.6.2 (7)", or just the one number when a copy carries no build.
    static func versionLine(_ version: String, _ build: String) -> String {
        build.isEmpty ? version : "\(version) (\(build))"
    }

    /// This application's own icon: the bundle's, or the file's as Finder draws it.
    static var icon: NSImage {
        NSImage(named: NSImage.applicationIconName) ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}
