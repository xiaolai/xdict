import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XDictAnywhere
import XDictCapture

/// **Hover, in Settings ▸ General** (plan-capture WI-3; ADR-0012 d.1: General holds how a lookup starts, beside the
/// lookup shortcut): the switch, the key and the gesture, the writing systems hover looks up — derived from the enabled
/// dictionaries' languages, shown and not chosen — the apps hover never reads, Screen Recording for the apps that share no
/// text (plan-capture WI-4), and why hover cannot read now, when it cannot. Rows, not a form: they sit in the General
/// pane's form.
public struct HoverSettings: View {
    let hover: HoverControl
    @State private var typedSite = ""
    @State private var siteAnswer: ExcludedSiteAnswer?

    public init(hover: HoverControl) {
        self.hover = hover
    }

    public var body: some View {
        Group {
            // Read back from the watcher: a start that failed says off, which is what is true.
            Toggle(isOn: Binding(get: { hover.isWatching }, set: { hover.setEnabled($0) })) {
                Text("Look up the word under the pointer")
                Text("Rest the pointer on a word while you use the key. Never in the apps below.")
            }
            .accessibilityIdentifier("hover.enabled")
            Picker(selection: policy(\.modifier)) {
                ForEach(HoverModifier.allCases, id: \.self) { Text(HoverSentences.modifier($0)).tag($0) }
            } label: {
                Text("Hover key")
            }
            .accessibilityIdentifier("hover.key")
            Picker(selection: policy(\.gesture)) {
                ForEach(HoverGesture.allCases, id: \.self) { Text(HoverSentences.gesture($0)).tag($0) }
            } label: {
                Text("Gesture")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("hover.gesture")
            // Capture's own choices (`HoverPolicy.settleChoices`), named by their length; no number of the view's.
            Picker(selection: Binding(get: { hover.settle }, set: { hover.setSettle($0) })) {
                ForEach(HoverPolicy.settleChoices) { Text(verbatim: HoverSentences.settle($0)).tag($0) }
            } label: {
                Text("Rest time")
                Text("How long the pointer rests on a word before hover looks it up.")
            }
            .accessibilityIdentifier("hover.settle")
            LabeledContent {
                Text(HoverSentences.scripts(hover.allowedScripts))
            } label: {
                Text("Looks up")
                Text("The writing systems of the dictionaries you use.")
            }
            .accessibilityIdentifier("hover.scripts")
            excludedApps
            excludedSites
            screenRecording
            if let notice = hover.notice {
                Text(HoverSentences.notice(notice))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("hover.notice")
            }
        }
    }

    /// **Screen Recording, the one place it is asked for** (plan-capture WI-4; ADR-0014 decision 7): showing the row reads
    /// the grant without calling anything that could prompt before the reader used it; its button is the only request.
    @ViewBuilder private var screenRecording: some View {
        LabeledContent {
            switch hover.screenRecording {
            case .notSetUp:
                Button { Task { await hover.setUpScreenRecording() } } label: { Text("Allow…") }  // placement: form-row
                    .accessibilityIdentifier("hover.screenRecording.allow")
            case .allowed:
                Text("Allowed")
            case .notAllowed, .couldNotTell:
                Button { Task { await hover.refreshScreenRecording() } } label: { Text("Check Again") }  // placement: form-row
                    .accessibilityIdentifier("hover.screenRecording.check")
            }
        } label: {
            Text("Screen Recording")
            Text(HoverSentences.screenRecording(hover.screenRecording))
        }
        .accessibilityIdentifier("hover.screenRecording")
        .task { await hover.refreshScreenRecording() }
    }

    /// The password managers by rule, as one row with what it covers a click away; then the reader's own, each removable.
    @ViewBuilder private var excludedApps: some View {
        DisclosureGroup {
            ForEach(HoverPolicy.defaultExcludedApps.sorted(), id: \.self) { AppName(bundleID: $0) }
        } label: {
            LabeledContent {
                Text("Always")
            } label: {
                Text("Password managers")
            }
        }
        .accessibilityIdentifier("hover.passwordManagers")
        ForEach(readersOwn, id: \.self) { app in
            LabeledContent {
                Button { remove(app) } label: { Text("Remove") }  // placement: form-row
            } label: {
                AppName(bundleID: app)
            }
        }
        LabeledContent {
            Button { addApp() } label: { Text("Add an App…") }  // placement: form-row
                .accessibilityIdentifier("hover.addApp")
        } label: {
            Text("Never look up in")
            Text("Hover reads nothing in these apps. Looking up a selection works in any app.")
        }
    }

    /// **The sites hover never reads**, each removable, and a field to add one: a name or a pasted address, kept as its
    /// host, refused with a sentence when it is not a site. With any site here, a page whose address cannot be read is
    /// not read either (`HoverPolicy.refuses`), and neither is the sentence around a selection on one.
    @ViewBuilder private var excludedSites: some View {
        ForEach(hover.excludedSites, id: \.self) { site in
            LabeledContent {
                Button { hover.removeExcludedSite(site) } label: { Text("Remove") }  // placement: form-row
            } label: {
                Text(verbatim: site)
            }
        }
        LabeledContent {
            HStack {
                TextField(text: $typedSite, prompt: Text(verbatim: "example.com")) { Text("Site") }
                    .labelsHidden()
                    .onSubmit(addSite)
                    .accessibilityIdentifier("hover.site.field")
                Button { addSite() } label: { Text("Add Site") }  // placement: form-row
                    .disabled(typedSite.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("hover.addSite")
            }
        } label: {
            Text("Never look up on")
            Text(siteAnswer.flatMap(HoverSentences.excludedSite)
                 ?? LocalizedStringResource("Hover reads nothing on these sites, nor on a page whose address cannot be read while any site is listed."))
        }
        .accessibilityIdentifier("hover.excludedSites")
    }

    private func addSite() {
        let answer = hover.addExcludedSite(typedSite)
        siteAnswer = answer
        if case .added = answer { typedSite = "" }
    }

    private var readersOwn: [String] {
        hover.policy.excludedApps.subtracting(HoverPolicy.defaultExcludedApps).sorted()
    }

    private func policy<Value>(_ field: WritableKeyPath<HoverPolicy, Value>) -> Binding<Value> {
        Binding(get: { hover.policy[keyPath: field] }, set: { value in
            var changed = hover.policy
            changed[keyPath: field] = value
            hover.setPolicy(changed)
        })
    }

    private func remove(_ app: String) {
        var changed = hover.policy
        changed.excludedApps.remove(app)
        hover.setPolicy(changed)
    }

    /// The bundle identifier is read from the app the reader picks, never typed: an identifier typed by hand is an
    /// exclusion that silently covers nothing.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let identifier = Bundle(url: url)?.bundleIdentifier else { return }
        var changed = hover.policy
        changed.excludedApps.insert(identifier)
        hover.setPolicy(changed)
    }
}

/// An app as a reader knows it, by its name; **the identifier only when that is all there is** (not installed).
private struct AppName: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Text(verbatim: FileManager.default.displayName(atPath: url.path))
                .help(bundleID)
        } else {
            Text(verbatim: bundleID)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
