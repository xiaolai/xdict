import SwiftUI

/// **XDict ▸ Acknowledgments** (plan-macos-v1 WI-10): every third-party notice the app carries, as shipped in
/// `Contents/Resources/Acknowledgments.txt` (`Tools/notices.py`; `make test` holds it to the crates the service links
/// and the fonts the bundle carries). The notices are legal texts and stay in their own language; only the window's
/// words are translated.
public struct AcknowledgmentsView: View {
    private let notices: String?

    /// `notices`: the file's text, or nil when the bundle lacks it, which the window then says rather than showing blank.
    public init(notices: String?) {
        self.notices = notices
    }

    /// The bundle's notices, or nil when they are missing or unreadable.
    public static func bundled(_ bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "Acknowledgments", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public var body: some View {
        Group {
            if let notices {
                // Headings as headings and the text in the body face, not a monospaced dump (UI review A-02).
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(Self.blocks(notices).enumerated()), id: \.offset) { _, block in
                            switch block {
                            case .heading(let text):
                                Text(verbatim: text).font(.title3.bold()).padding(.top, 8)
                            case .text(let text):
                                Text(verbatim: text).font(.body).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            } else {
                Text("The acknowledgments are missing from this copy of XDict.")
                    .padding()
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 400, idealHeight: 560)
    }

    enum Block: Equatable {
        case heading(String)
        case text(String)
    }

    /// The notices file read as headings (a line underlined with "=") and paragraphs (runs of lines between blank ones).
    static func blocks(_ notices: String) -> [Block] {
        let lines = notices.components(separatedBy: "\n")
        var blocks: [Block] = [], paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.text(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            if !line.isEmpty, !next.isEmpty, next.allSatisfy({ $0 == "=" }) {
                flush()
                blocks.append(.heading(line))
                index += 2
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { paragraph.append(line) }
            index += 1
        }
        flush()
        if case .text(let first) = blocks.first, !first.contains("\n") { blocks[0] = .heading(first) }
        return blocks
    }
}
