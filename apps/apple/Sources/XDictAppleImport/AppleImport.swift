// XDictAppleImport — Apple's dictionaries, converted to MDX once (ADR-0011).
//
// **Provenance** (ADR-0011 decision 12; the file-by-file record is `dev-docs/apple-import-provenance.md`). Adopted from
// the dict2mdx spike's Swift port (`spike-swift/Sources/XDictCore`), whose Python reference stays outside this
// repository as an oracle, never as code to copy. What each part was written from:
//
// - `AppleDict.swift` (the bundle's `Info.plist`, `Body.data`, `KeyText.data`) and `Transform.swift`,
//   `HTMLEntities.swift` (entry XML to HTML): Apple's installed `*.dictionary` bundles as observed, byte by byte, and
//   the XML 1.0 and HTML specifications. No Apple code, and no other converter's.
// - `MDictWriter.swift` (MDX and MDD 2.0): the MIT-licensed writemdict format description, as `core/xdict-mdx` is.
// - `KeyOrder.swift` (the order records are written in): what XDict's own core reader folds keys to
//   (`core/xdict-mdx/src/text.rs`, `fold`; `core/xdict-mdx/src/lib.rs`, the rules per file kind). It replaces the
//   spike's rule, which mirrored a GPL tool's regex with no recorded origin.
// - `Zlib.swift`: the system's libz, called through its documented interface.
//
// No GPL or AGPL source was read for any of it (ADR-0001). The spike's own MDX reader is not here: the core's reader is
// the production check of every output (ADR-0011 decision 3), and a test-only reader lives with the tests.

/// What the converter is, apart from what it converts.
public enum AppleImport {
    /// **Bumped with any change to the bytes written** (ADR-0011 decision 7): an imported copy made by an older revision
    /// is offered a fresh conversion.
    public static let converterRevision = 1
}
