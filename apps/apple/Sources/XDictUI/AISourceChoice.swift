import Foundation
import XDictAI

/// **Settings ▸ AI's source as one native single choice** (UI32): the six rows the pane offers, in the order of what
/// each costs to set up. Two of them are the same provider kind — an endpoint on this Mac and one in the cloud — so the
/// choice, not the kind, is what the pane's picker selects; `MeaningPreferences` keeps storing the kind and the flag.
public enum AISourceChoice: String, CaseIterable, Hashable, Sendable {
    case off, apple, local, cloud, codex, claude

    /// The row's accessibility identifier suffix (`ai.source.<identifier>`), as the UI tour and E2E read it.
    public var identifier: String { rawValue }

    /// The provider kind stored for this choice; nil turns the feature off.
    public var kind: AIProviderKind? {
        switch self {
        case .off: nil
        case .apple: .appleOnDevice
        case .local, .cloud: .http
        case .codex: .codexCLI
        case .claude: .claudeCLI
        }
    }

    /// Whether the endpoint is the cloud one (the key's row and its caveat).
    public var cloud: Bool { self == .cloud }

    /// The choice that describes what is stored.
    public static func of(kind: AIProviderKind?, cloud: Bool) -> AISourceChoice {
        switch kind {
        case nil: .off
        case .appleOnDevice: .apple
        case .http: cloud ? .cloud : .local
        case .codexCLI: .codex
        case .claudeCLI: .claude
        }
    }
}

/// **The Codex sign-in's own lines, read for the two things the reader needs** (UI33): the web address to open and the
/// one-time code to enter. Read conservatively: a code is taken only from a line that says "code" (or the line right
/// after it), and only a web address is offered as a link; everything else stays in the raw lines under Details.
public struct CodexLogin: Equatable, Sendable {
    public var url: URL?
    public var code: String?

    public init(url: URL?, code: String?) {
        self.url = url
        self.code = code
    }

    public static func parse(_ lines: [String]) -> CodexLogin {
        let clean = lines.map(stripEscapes)
        var url: URL?
        var code: String?
        for (index, line) in clean.enumerated() {
            if url == nil { url = webAddress(in: line) }
            if code == nil, line.range(of: "code", options: .caseInsensitive) != nil {
                code = codeToken(in: line) ?? clean.dropFirst(index + 1).first.flatMap(codeToken)
            }
        }
        return CodexLogin(url: url, code: code)
    }

    /// Terminal colour sequences (`ESC [ … letter`) removed.
    static func stripEscapes(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    static func webAddress(in line: String) -> URL? {
        guard let range = line.range(of: "https?://[^\\s<>\"']+", options: .regularExpression) else { return nil }
        let text = String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}"))
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    /// A token of capitals and digits, four or more, optionally in two hyphenated groups, with at least one capital
    /// letter or hyphen (so a bare number of minutes is never a code).
    static func codeToken(in line: String) -> String? {
        let pattern = "\\b[A-Z0-9]{4,}(?:-[A-Z0-9]{4,})?\\b"
        var search = line.startIndex..<line.endIndex
        while let range = line.range(of: pattern, options: .regularExpression, range: search) {
            let token = String(line[range])
            if token.contains("-") || token.contains(where: \.isLetter) { return token }
            search = range.upperBound..<line.endIndex
        }
        return nil
    }
}
