import Foundation
import Testing
@testable import XDictEntryView

/// **XDict's phonetic faces** (owner, 2026-10-16): Noto Sans in the Sans reading style, Charis in Serif, bundled
/// unmodified and served through XDict's own scheme (no network), under family names a dictionary cannot mean.
@MainActor
struct PhoneticFontTests {
    /// `apps/apple/Resources/Fonts`, the folder the bundle copies.
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Resources/Fonts")

    static let files = ["NotoSans-Regular.ttf", "NotoSans-Italic.ttf", "NotoSans-Bold.ttf", "NotoSans-BoldItalic.ttf",
                        "Charis-Regular.ttf", "Charis-Italic.ttf", "Charis-Bold.ttf", "Charis-BoldItalic.ttf"]

    @Test func theEightFacesAreTheBundledFiles() throws {
        #expect(Set(EntryFonts.faces.map(\.file)) == Set(Self.files))
        #expect(EntryFonts.faces.count == 8)
        for file in Self.files {
            let data = try Data(contentsOf: Self.folder.appending(path: file))
            #expect(data.prefix(4) == Data([0, 1, 0, 0]), "\(file) is not a TrueType file")
        }
        for notice in ["OFL-NotoSans.txt", "OFL-Charis.txt"] {
            let text = try String(contentsOf: Self.folder.appending(path: notice), encoding: .utf8)
            #expect(text.contains("SIL OPEN FONT LICENSE Version 1.1"), "\(notice)")
        }
    }

    @Test func onlyTheEightNamesAreAFontRoute() {
        for file in Self.files {
            #expect(EntryRoutes.route(URL(string: "xdict://d/font/\(file)"), method: "GET") == .font(file))
        }
        for url in ["xdict://d/font/", "xdict://d/font/Other.ttf", "xdict://d/font/../r/NotoSans-Regular.ttf",
                    "xdict://d/font/NotoSans-Regular.ttf?x=1", "xdict://d/font/notosans-regular.ttf",
                    "xdict://d/font/%4EotoSans-Regular.ttf", "xdict://d/font/Fonts/NotoSans-Regular.ttf"] {
            #expect(EntryRoutes.route(URL(string: url), method: "GET") == .refused(.notAFont), "\(url)")
        }
        #expect(EntryRoutes.route(URL(string: "xdict://d/font/Charis-Regular.ttf"), method: "POST") == .refused(.notGet))
    }

    @Test func aFaceIsServedFromTheFolderWithThePolicyAndNotAskedOfTheDictionary() async throws {
        let content = FakeContent("a")
        let server = EntryResourceServer(content: content, fonts: Self.folder) { "Image from \($0)" }
        let url = URL(string: "xdict://d/entry/run") ?? URL(fileURLWithPath: "/")
        server.register(EntryDocument(html: Data("<p>run</p>".utf8), policy: corePolicy), at: url)
        guard case .answer(let answer) = await server.serve(request("xdict://d/font/Charis-Bold.ttf")) else {
            Issue.record("a bundled face was refused")
            return
        }
        #expect(answer.status == 200)
        #expect(answer.headers["Content-Type"] == "font/ttf")
        #expect(answer.headers["Content-Security-Policy"] == corePolicy)
        #expect(answer.body == (try Data(contentsOf: Self.folder.appending(path: "Charis-Bold.ttf"))))
        #expect(content.asked.isEmpty, "the dictionary was asked for XDict's own font")
        guard case .refuse = await server.serve(request("xdict://d/font/Other.ttf")) else {
            Issue.record("a name outside the eight was answered")
            return
        }
        let missing = EntryResourceServer(content: content, fonts: nil) { $0 }
        missing.register(EntryDocument(html: Data(), policy: corePolicy), at: url)
        guard case .refuse = await missing.serve(request("xdict://d/font/Charis-Bold.ttf")) else {
            Issue.record("a face was answered with no font folder")
            return
        }
    }

    @Test func theFrameDeclaresTheFacesUnderXDictsNames() {
        let css = EntryReadingFrame.tokensCSS
        for face in EntryFonts.faces {
            let family = face.file.hasPrefix("Charis") ? "XDict Phonetic Serif" : "XDict Phonetic Sans"
            #expect(css.contains(#"@font-face{font-family:"\#(family)";src:url("xdict://d/font/\#(face.file)") format("truetype");"#
                                 + "font-weight:\(face.weight);font-style:\(face.italic ? "italic" : "normal")}"), "\(face.file)")
        }
        // New York by default since parity P18 (2026-10-17), Charis with it; Sans the reader's alternative.
        #expect(css.contains(#"--xdict-font-phon:"XDict Phonetic Serif", "Charis", "Charis SIL", "Doulos SIL", "Gentium", "#
                             + #""Gentium Plus", var(--xdict-font);"#))
        #expect(css.contains(#":root[data-xdict-face=sans]{--xdict-font:-apple-system, "Helvetica Neue", var(--xdict-font-cjk), sans-serif;"#
                             + #"--xdict-font-cjk:"PingFang SC", "Hiragino Sans GB";--xdict-font-phon:"XDict Phonetic Sans", "Charis", "#))
    }

    /// A dictionary rule inside a transcription that the core normalized to XDict's text face (OALD's, MWU's) is the
    /// phonetic face there; the accent tags keep the text face.
    @Test func insideATranscriptionTheTextFaceIsThePhoneticFace() {
        #expect(EntryReadingFrame.typeCSS.contains("[data-xdict-phon]{--xdict-font:var(--xdict-font-phon);"))
        #expect(EntryReadingFrame.controlsCSS().contains("[data-xdict-tag]{font-family:var(--xdict-font-text);"))
        #expect(EntryReadingFrame.tokensCSS.contains("--xdict-font-text:var(--xdict-font);"))
    }
}
