import Foundation

/// **The shell owns the colours a page's scripts write** (ADR-0010). The core maps every colour in the entry's HTML and
/// CSS to a palette token, but it cannot see a script's run-time `style.color = '#000'` (ODE's `o3.js` on `.tki`). The
/// guard maps those in the shell's world, by the core's rule, and drops what "Plain by default" drops.
extension EntryScripts {
    /// The palette's light values, the fallback each token is written with, as the core writes it (`colour.rs`).
    private static var fallbacksJSON: String {
        let pairs = Dictionary(uniqueKeysWithValues: EntryReadingFrame.colours.map { ($0.0, $0.1) })
        let data = (try? JSONSerialization.data(withJSONObject: pairs, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The core's rule, with no DOM (`core/xdict-entry/src/colour.rs`; parity with it is
    /// `conformance/fixtures/colour-tokens.tsv`): a text colour read in OKLCH, made opaque over white. Near-white is
    /// `--xdict-text`, a neutral (C < 0.035) is `--xdict-text` below L 0.45 and `--xdict-text-2` above, anything else
    /// the one accent, `--xdict-accent` (owner, 2026-10-16: flatten). `plan` is what one element's inline declarations become.
    static var colourCore: String { colourCore(.bundled) }
    static func colourCore(_ style: EntryStyle) -> String { style.script("colour-core.js", ["fallbacks": fallbacksJSON]) }

    /// The guard on the page: style attributes changed and elements added are queued, and a capped batch is mapped per
    /// animation frame (a timer stands in where no frame comes), with the observer disconnected while it writes, so its
    /// own writes never queue more. `window.__xdictColours` (the shell's world only) counts what it did.
    static var colourGuard: String { EntryStyle.bundled.script("colour-guard.js") }
}
