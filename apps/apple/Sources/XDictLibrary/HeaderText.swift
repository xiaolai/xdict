import Foundation

/// **The name a dictionary is shown by** (R11): the reader's own name if they gave one; else the header's title, read as
/// plain text, unless it is empty or MdxBuilder's placeholder; else the file's name without its extension.
public enum DisplayName {
    public static func of(readers: String?, title: String, fileName: String) -> String {
        if let readers = readers?.trimmingCharacters(in: .whitespacesAndNewlines), !readers.isEmpty { return readers }
        let plain = HeaderText.plain(title)
        if !plain.isEmpty { return plain }
        let stem = (fileName as NSString).deletingPathExtension
        return stem.isEmpty ? fileName : stem
    }
}

/// **A header's text as the reader reads it**: the title and the description are written by whoever made the file, often
/// with markup in them. Tags are dropped (a `<br>` or a closed paragraph becomes a line break), the five entities and
/// numeric references are read, runs of spaces collapse, and MdxBuilder's placeholders count as nothing.
public enum HeaderText {
    /// What MdxBuilder writes when its author left a field alone.
    static let placeholders: Set<String> = ["title (no html code allowed)", "description (no html code allowed)"]

    public static func plain(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "<", let close = text[index...].firstIndex(of: ">") {
                let tag = text[text.index(after: index)..<close].lowercased()
                    .trimmingCharacters(in: .whitespaces)
                if tag.hasPrefix("br") || tag == "/p" || tag == "/div" || tag == "/li" { out.append("\n") }
                index = text.index(after: close)
            } else if character == "&", let semicolon = text[index...].prefix(10).firstIndex(of: ";"),
                      let decoded = entity(String(text[text.index(after: index)..<semicolon])) {
                out.append(decoded)
                index = text.index(after: semicolon)
            } else {
                out.append(character)
                index = text.index(after: index)
            }
        }
        let lines = out.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{A0}" }).joined(separator: " ")
        }.filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        return placeholders.contains(joined.lowercased()) ? "" : joined
    }

    static func entity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            let number = name.hasPrefix("#x") || name.hasPrefix("#X") ? UInt32(name.dropFirst(2), radix: 16)
                : name.hasPrefix("#") ? UInt32(name.dropFirst()) : nil
            return number.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }
}
