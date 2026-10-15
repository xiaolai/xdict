// XDictEntryLab: a development instrument for the entry view (plan-macos-v1 WI-4), run by the E2E stages on the E2E Mac
// only — never on the Mac that builds, and never shipped in XDict.app. It hosts the production `EntryViewController`,
// feeds it from the core linked in directly (`LabCore`), and writes what happened as JSON. `Options.swift` lists the
// modes and the one flag that exists nowhere else: `--disable-layer`.
import AppKit
import Foundation
import XDictEntryView

enum LabMain {
    static func die(_ why: String) -> Never {
        FileHandle.standardError.write(Data("XDictEntryLab: \(why)\n".utf8))
        exit(2)
    }
}

@MainActor
final class LabDelegate: NSObject, NSApplicationDelegate {
    let options: LabOptions
    var hostile: HostileRun?
    var reader: ReaderRun?

    init(options: LabOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await run()
            } catch {
                LabMain.die("\(error)")
            }
        }
    }

    private func run() async throws {
        guard let out = options.out else { throw LabFailure(description: "--out is missing") }
        let cache = FileManager.default.temporaryDirectory.appending(path: "xdict-lab-core-\(ProcessInfo.processInfo.processIdentifier)")
        let core = try LabCore(cache: cache, stripOffForTests: options.stripOffForTests)
        switch options.mode {
        case .hostile:
            guard let fixture = options.fixture, let casesFile = options.cases else {
                throw LabFailure(description: "--hostile needs a fixture folder and --cases")
            }
            let cases = try JSONDecoder().decode(HostileCases.self, from: Data(contentsOf: casesFile)).cases
            let run = HostileRun(options: options, content: try core.open(fixture), cases: cases)
            hostile = run
            run.start()
        case .faultSwitch(let fault):
            guard let fixture = options.fixture else { throw LabFailure(description: "--fault-switch needs --fixture") }
            try Report.write(try await FaultRun.run(fault, options: options, content: try core.open(fixture)), to: out)
            exit(0)
        case .binding:
            try Report.write(try await BindingRun.run(options: options, core: core), to: out)
            exit(0)
        case .reader:
            guard let fixture = options.fixture else { throw LabFailure(description: "--reader needs a fixture folder") }
            let run = ReaderRun(options: options, content: try core.open(fixture))
            reader = run
            try await run.start()
        case .corpus:
            try Report.write(try await CorpusRun.run(options: options, core: core), to: out)
            exit(0)
        case .gallery:
            try Report.write(try await GalleryRun.run(options: options, core: core), to: out)
            exit(0)
        case nil:
            throw LabFailure(description: "no mode")
        }
    }
}

let options: LabOptions
do {
    options = try LabOptions.parse(CommandLine.arguments)
} catch {
    LabMain.die("\(error)")
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = LabDelegate(options: options)
    app.delegate = delegate
    app.run()
}
