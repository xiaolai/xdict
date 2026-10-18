import Foundation

/// Walking the source tree, for the checks that read code rather than run it. Adapted from XiaolaiDict's
/// `SourceScan`, which was extracted after two copies of a walk drifted into the same defect: a directory that could
/// not be read was skipped silently, and the check went on passing over what remained.
public enum SourceScan {
    /// A directory that could not be walked, or a file that could not be read. **Thrown, never skipped**: a scanner
    /// that silently reads less than it claims passes forever and guards nothing.
    public struct Unreadable: Error, CustomStringConvertible {
        public let path: String
        public let underlying: String
        public var description: String { "could not read \(path): \(underlying)" }
    }

    /// Every `.swift` file under `root`, with its text. A root that does not exist is unreadable, not empty.
    public static func files(under root: URL) throws -> [(file: URL, text: String)] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Unreadable(path: root.path, underlying: "no such directory")
        }
        var failure: (any Error)?
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in failure = error; return false })
        else { throw Unreadable(path: root.path, underlying: "the walk could not start") }
        var found: [(file: URL, text: String)] = []
        for case let file as URL in walk where file.pathExtension == "swift" {
            do {
                found.append((file, try String(contentsOf: file, encoding: .utf8)))
            } catch {
                throw Unreadable(path: file.path, underlying: "\(error)")
            }
        }
        // Checked after the walk: the handler runs during it, and returning `false` stops it rather than throwing.
        if let failure { throw Unreadable(path: root.path, underlying: "\(failure)") }
        return found.sorted { $0.file.path < $1.file.path }
    }

    /// The modules a file imports, in the order written: any run of attributes (`@testable`, `@_spi(…)`), an optional
    /// access level, `import`, an optional kind (`import struct X.Y` binds `X`), then the module, whose dotted path is
    /// kept (`Carbon.HIToolbox`). **Read as Swift reads it**: comments and string contents are blanked first, `;` ends
    /// a statement as a line break does, and a module may be written in backticks.
    public static func imports(in code: String) -> [String] {
        let text = codeOnly(code).replacingOccurrences(of: ";", with: "\n")
        let statement = /^[ \t]*(?:@\w+(?:\([^)]*\))?\s*)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(struct|class|enum|protocol|typealias|func|var|let)\s+)?(`?[A-Za-z_][A-Za-z0-9_]*`?(?:\.`?[A-Za-z_][A-Za-z0-9_]*`?)*)/
            .anchorsMatchLineEndings()
        return text.matches(of: statement).map { match in
            let path = String(match.output.2).replacingOccurrences(of: "`", with: "")
            guard match.output.1 != nil, let last = path.lastIndex(of: ".") else { return path }
            return String(path[path.startIndex..<last])
        }
    }

    /// **`code` as the compiler runs it**: comments gone and a string's own text gone, **but every interpolation kept**,
    /// since `"\(term.context)"` evaluates `term.context` exactly as code outside a string does. Interpolations nest
    /// (a string inside one is read the same way); a raw string's interpolation is `\#(`. Newlines inside strings and
    /// comments are kept, so a line number here is the source's.
    public static func codeWithInterpolations(_ code: String) -> String {
        let characters = Array(code)
        func starts(_ token: String, at index: Int) -> Bool {
            let token = Array(token)
            return index + token.count <= characters.count
                && Array(characters[index..<(index + token.count)]) == token
        }
        func newlines(_ range: Range<Int>) -> String {
            String(repeating: "\n", count: characters[range].filter { $0 == "\n" }.count)
        }
        // Code until the end — or, inside an interpolation, until the `)` that closes it, which is consumed.
        func program(_ index: inout Int, interpolated: Bool) -> String {
            var out = "", depth = 0
            while index < characters.count {
                if starts("//", at: index) {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                    continue
                }
                if starts("/*", at: index) {
                    let begun = index
                    var nesting = 0
                    repeat {
                        if starts("/*", at: index) { nesting += 1; index += 2 }
                        else if starts("*/", at: index) { nesting -= 1; index += 2 }
                        else { index += 1 }
                    } while nesting > 0 && index < characters.count
                    out += " " + newlines(begun..<min(index, characters.count))
                    continue
                }
                if interpolated {
                    if characters[index] == "(" { depth += 1 }
                    if characters[index] == ")" {
                        if depth == 0 { index += 1; return out }
                        depth -= 1
                    }
                }
                var hashes = 0
                while index + hashes < characters.count, characters[index + hashes] == "#" { hashes += 1 }
                if index + hashes < characters.count, characters[index + hashes] == "\"" {
                    out += string(&index, hashes: hashes)
                    continue
                }
                let run = max(hashes, 1)
                out += String(characters[index..<min(index + run, characters.count)])
                index += run
            }
            return out
        }
        // A string literal: its text dropped, its interpolations read as code.
        func string(_ index: inout Int, hashes: Int) -> String {
            let quote = starts("\"\"\"", at: index + hashes) ? "\"\"\"" : "\""
            let close = quote + String(repeating: "#", count: hashes)
            let escape = "\\" + String(repeating: "#", count: hashes)
            index += hashes + quote.count
            var out = "\""
            while index < characters.count, !starts(close, at: index) {
                if starts(escape + "(", at: index) {
                    index += escape.count + 1
                    out += "\\(" + program(&index, interpolated: true) + ")"
                } else if starts(escape, at: index) {
                    index += escape.count + 1
                } else {
                    if characters[index] == "\n" { out += "\n" }
                    index += 1
                }
            }
            index += close.count
            return out + "\""
        }
        var index = 0
        return program(&index, interpolated: false)
    }

    /// `code` with every comment replaced by a space and every string literal's contents removed, so neither can
    /// look like an import or hide one. Block comments nest, as Swift's do; a raw string ends only at a quote followed
    /// by as many `#` as opened it, and has no backslash escapes.
    public static func codeOnly(_ code: String) -> String {
        let characters = Array(code)
        func starts(_ token: String, at index: Int) -> Bool {
            let token = Array(token)
            return index + token.count <= characters.count
                && Array(characters[index..<(index + token.count)]) == token
        }
        var out = "", index = 0
        while index < characters.count {
            if starts("//", at: index) {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if starts("/*", at: index) {
                var depth = 0
                repeat {
                    if starts("/*", at: index) { depth += 1; index += 2 }
                    else if starts("*/", at: index) { depth -= 1; index += 2 }
                    else { index += 1 }
                } while depth > 0 && index < characters.count
                out += " "
            } else {
                var hashes = 0
                while index + hashes < characters.count, characters[index + hashes] == "#" { hashes += 1 }
                guard index + hashes < characters.count, characters[index + hashes] == "\"" else {
                    // `#if`, `#available`, or any character that opens nothing.
                    let run = max(hashes, 1)
                    out += String(characters[index..<(index + run)])
                    index += run
                    continue
                }
                let quote = starts("\"\"\"", at: index + hashes) ? "\"\"\"" : "\""
                let close = quote + String(repeating: "#", count: hashes)
                index += hashes + quote.count
                while index < characters.count, !starts(close, at: index) {
                    index += characters[index] == "\\" && hashes == 0 ? 2 : 1
                }
                index += close.count
                out += "\"\""
            }
        }
        return out
    }
}
