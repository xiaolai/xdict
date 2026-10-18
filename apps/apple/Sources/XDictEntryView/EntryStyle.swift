import Foundation
import XDictTokens

/// **The reading style's text** (plan-verification §4.6): the frame's CSS and the shell's scripts, kept as files in
/// `Style/` so a person edits CSS as CSS. The app uses `bundled` and nothing else: the files' text compiled into the
/// binary by `Tools/reading-style-gen.py`, so no style file exists on disk for anything to replace, and the scripts
/// that run in the shell's world (`EntryPane.world`) are the ones that were reviewed and built. `EntryStyleFilesTests`
/// holds the compiled text to the files byte for byte.
///
/// The development lab's gallery alone reads a directory of them instead (`--style-dir`), so a style change reaches a
/// picture without a rebuild. The directory is read in the lab, never here: this module has no code that reads a
/// style file, and `Tools/build-bundle.sh` refuses an app binary carrying the lab's flag.
public struct EntryStyle: Sendable, Equatable {
    let files: [String: String]

    /// What XDict ships.
    public static let bundled = EntryStyle(files: EntryStyleFiles.text)

    /// The names every style must have, `bundled`'s.
    public static var names: [String] { EntryStyleFiles.text.keys.sorted() }

    private init(files: [String: String]) { self.files = files }

    /// A style from texts the lab read, under exactly `names`.
    package init(replacing texts: [String: String]) throws {
        guard Set(texts.keys) == Set(Self.names) else {
            let missing = Set(Self.names).subtracting(texts.keys).sorted(), extra = Set(texts.keys).subtracting(Self.names).sorted()
            throw EntryStyleError(description: "the style files differ from XDict's: missing \(missing), unknown \(extra)")
        }
        self.files = texts
    }

    /// The file's text, less the one newline that ends a file.
    func text(_ name: String) -> String {
        guard let text = files[name] else { preconditionFailure("no style file \(name)") }
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// A stylesheet: its lines joined with nothing between them (the CSS is written a rule or part of one per line),
    /// each without its indentation, and a line that is wholly a `/* … */` comment left out; then its `{{name}}`s, and
    /// the tokens' `{{fill-<name>}}`s (`Tokens.ReadingStyle.fills`: values where `var()` cannot go, a media query).
    func css(_ name: String, _ values: [String: String] = [:]) -> String {
        let lines = text(name).split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> Substring? in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            return trimmed.hasPrefix("/*") && trimmed.hasSuffix("*/") ? nil : trimmed
        }
        return Self.fill(lines.joined(), values.merging(Tokens.ReadingStyle.fills) { given, _ in given }, in: name)
    }

    /// A script, as written; then its `{{name}}`s.
    func script(_ name: String, _ values: [String: String] = [:]) -> String { Self.fill(text(name), values, in: name) }

    /// Each `{{name}}` (lowercase letters, digits, hyphens) replaced by `values[name]`, in one pass: a value is never
    /// read for placeholders. A placeholder with no value is a mistake in the file, and stops the process.
    static func fill(_ template: String, _ values: [String: String], in file: String) -> String {
        var out = "", rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            let name = after.prefix { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
            if !name.isEmpty, after.dropFirst(name.count).hasPrefix("}}") {
                guard let value = values[String(name)] else { preconditionFailure("\(file): no value for {{\(name)}}") }
                out += value
                rest = after.dropFirst(name.count + 2)
            } else {
                out += "{"
                rest = rest[rest.index(after: open.lowerBound)...]
            }
        }
        return out + rest
    }
}

/// Why a style directory was not taken.
public struct EntryStyleError: Error, CustomStringConvertible {
    public let description: String
}
