import Foundation
import Testing
@testable import XDictEntryView

/// **What the entry view injects is the text of `Sources/XDictEntryView/Style/`** (plan-verification §4.6): the files a
/// person edits, compiled into the binary by `Tools/reading-style-gen.py`, reach the page unchanged but for the
/// documented joins (a stylesheet's lines run together, its comment lines left out) and the `{{name}}`s filled.
struct EntryStyleFilesTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/XDictEntryView/Style")

    static func onDisk() throws -> [String: String] {
        var out: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path)
        where name.hasSuffix(".css") || name.hasSuffix(".js") {
            out[name] = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
        }
        return out
    }

    /// Byte for byte: every file is compiled in, as it is on disk, and nothing else is. A file edited without running
    /// the generator fails here.
    @Test func theCompiledTextIsTheFiles() throws {
        let disk = try Self.onDisk()
        #expect(disk.count >= 20, "the walk read \(disk.count) files of \(Self.folder.path)")
        #expect(Set(disk.keys) == Set(EntryStyleFiles.text.keys))
        for (name, text) in disk.sorted(by: { $0.key < $1.key }) {
            #expect(EntryStyleFiles.text[name] == text, "\(name) is not what is compiled in: run Tools/reading-style-gen.py")
        }
    }

    /// And what is installed on the page is that text: each script with nothing to fill whole, in order, and each
    /// stylesheet with nothing to fill joined, inside the frame's script.
    @Test func theInstalledScriptsAreTheFiles() throws {
        let disk = try Self.onDisk()
        func script(_ name: String) throws -> String {
            let text = try #require(disk[name])
            #expect(!text.contains("{{"), "\(name) has a placeholder")
            return String(text.dropLast())   // the newline that ends a file
        }
        let installed = EntryScripts.installed(.light, frame: .all)
        #expect(installed[0] == (try script("find-core.js")))
        #expect(installed[1] == (try script("find.js")))
        #expect(installed[2] == (try script("readability-core.js")))
        #expect(installed[3].hasPrefix(try script("frame-core.js") + "\n"))
        #expect(installed[3].contains("\n" + (try script("colour-guard.js")) + "\n"))
        #expect(Array(installed[4...]) == (try ["placeholder-clicks.js", "speaker-clicks.js", "disclosure-core.js",
                                                "disclosure.js", "pron-run-core.js", "pron-run.js"].map(script)))
        for name in ["column.css", "type.css", "reading-labels.css"] {
            let joined = try #require(disk[name]).split(separator: "\n").map { $0.drop { $0 == " " } }
                .filter { !($0.hasPrefix("/*") && $0.hasSuffix("*/")) }.joined()
            #expect(installed[3].contains(String(data: try JSONEncoder().encode(joined), encoding: .utf8)?
                .dropFirst().dropLast() ?? "-"), "\(name) is not in the frame's script")
        }
    }

    /// The lab's style reaches the page in place of the compiled one, and only a complete one is taken.
    @Test func aReplacedStyleIsWhatIsInstalled() throws {
        var texts = try Self.onDisk()
        texts["find.js"] = "/* replaced */\n"
        let style = try EntryStyle(replacing: texts)
        #expect(EntryScripts.installed(.light, frame: .all, style: style)[1] == "/* replaced */")
        #expect(EntryScripts.installed(.light, frame: .all)[1] != "/* replaced */")
        texts["find.js"] = nil
        #expect(throws: EntryStyleError.self) { try EntryStyle(replacing: texts) }
        texts["find.js"] = ""
        texts["extra.css"] = ""
        #expect(throws: EntryStyleError.self) { try EntryStyle(replacing: texts) }
    }

    /// The fill: one pass, a `{` before a placeholder kept, a value never read for placeholders.
    @Test func placeholdersAreFilledOnce() {
        #expect(EntryStyle.fill("a{{{x}}}b{{y}}", ["x": "{{y}}", "y": "Y"], in: "t") == "a{{{y}}}bY")
        #expect(EntryStyle.fill("{{ x }}{}", [:], in: "t") == "{{ x }}{}")
    }
}
