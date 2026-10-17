import Foundation
import JavaScriptCore
import Testing
@testable import XDictEntryView

/// **The shell owns the colours a page's scripts write** (ADR-0010): the core maps every colour it can read, but not a
/// `style.color = '#000'` made at run time (ODE's `o3.js`). The guard's pure half runs here in JavaScriptCore.
struct ColourGuardTests {
    static func core() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
        context.evaluateScript(EntryScripts.colourCore)
        return context
    }

    /// The core's samples (`conformance/fixtures/colour-tokens.tsv`), read by the core's test too: each takes the same
    /// token here.
    @Test func theShellMapsTheCoresSamplesToTheSameTokens() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try String(contentsOf: root.appending(path: "conformance/fixtures/colour-tokens.tsv"), encoding: .utf8)
        let context = try Self.core()
        var checked = 0
        for line in fixture.split(separator: "\n") where !line.hasPrefix(";") && !line.isEmpty {
            let parts = line.split(separator: "\t").map(String.init)
            try #require(parts.count == 2, "\(line)")
            context.setObject(parts[0], forKeyedSubscript: "sample" as NSString)
            let css = context.evaluateScript("XDictColourCore.text(XDictColourCore.parse(sample))")?.toString()
            #expect(css?.hasPrefix("var(--xdict-\(parts[1]), ") == true, "\(parts[0]): \(css ?? "nil"), want \(parts[1])")
            checked += 1
        }
        #expect(checked >= 30)
    }

    /// What the guard does to one element's inline style: a script's colour becomes a token, keeping its priority; a
    /// background, border, outline or shadow is dropped; a token or a keyword is left alone, so the guard's own write
    /// never asks for another.
    @Test func aScriptWrittenColourBecomesAToken() throws {
        let context = try Self.core()
        func plan(_ declarations: String) -> String? {
            context.evaluateScript("JSON.stringify(XDictColourCore.plan(\(declarations), XDictColourCore.parse))")?.toString()
        }
        #expect(plan(##"[["color","rgb(0, 0, 0)",""]]"##) == ##"[["set","color","var(--xdict-text, #000000)",""]]"##)
        #expect(plan(##"[["color","#c00000","important"]]"##) == ##"[["set","color","var(--xdict-accent, #055959)","important"]]"##)
        #expect(plan(##"[["background-color","red",""],["border-top-width","1px",""],["box-shadow","1px 1px red",""],"##
                     + ##"["text-shadow","none",""],["outline-color","red",""],["background-image","none",""]]"##)
                == ##"[["remove","background-color"],["remove","border-top-width"],["remove","box-shadow"],"##
                + ##"["remove","text-shadow"],["remove","outline-color"],["remove","background-image"]]"##)
        #expect(plan(##"[["color","var(--xdict-text, #1d1d1f)",""],["color","inherit",""],["color","currentcolor",""],"##
                     + ##"["font-weight","bold",""]]"##) == "[]", "a token, a keyword and anything else are left alone")
        #expect(plan(##"[["-webkit-text-fill-color","#000",""]]"##) == ##"[["remove","-webkit-text-fill-color"]]"##)
        // A border that draws nothing is the core's own `<hr>` gap (Q9, `border:0`): dropping it brings back the UA's
        // inset line (AHD's "leek", gallery 2026-10-16).
        #expect(plan(##"[["border-top-width","0px",""],["border-top-style","none",""],["border-left-width","0",""],"##
                     + ##"["outline-style","hidden",""]]"##) == "[]", "a border that draws nothing stays")
    }

    /// The contrast correction that swapped a failing colour for black or white is gone: the palette's tokens read on
    /// every surface by construction (`colour.rs`), and that correction is what turned ODE's `#000` white in dark.
    @Test func theLegacyContrastCorrectionIsGone() {
        for scheme in [EntryColourScheme.light, .dark] {
            let script = EntryScripts.appearance(scheme)
            #expect(!script.contains("data-xdict-recoloured"), "\(scheme)")
            #expect(!script.contains("replacement("), "\(scheme)")
            #expect(script.contains("XDictColourCore"), "\(scheme): the guard runs in both themes")
        }
        #expect(!EntryScripts.readabilityCore.contains("replacement"))
        // With the correction gone, the core's tokens are defined per theme even in "Original style" (no frame), or its
        // colours would fall back to their light values on a dark page.
        let original = EntryScripts.appearance(.dark, frame: [])
        #expect(original.contains(":root[data-xdict-theme=dark]{--xdict-bg:#1e1e1e;"))
        #expect(!original.contains("--xdict-font:"))
    }
}
