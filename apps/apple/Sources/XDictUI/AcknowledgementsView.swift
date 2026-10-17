import SwiftUI

/// **XDict ▸ Acknowledgements** (plan-macos-v1 WI-10): every third-party notice the app carries, as shipped in
/// `Contents/Resources/Acknowledgements.txt` (`Tools/notices.py`; `make test` holds it to the crates the service links
/// and the fonts the bundle carries). The notices are legal texts and stay in their own language; only the window's
/// words are translated.
public struct AcknowledgementsView: View {
    private let notices: String?

    /// `notices`: the file's text, or nil when the bundle lacks it, which the window then says rather than showing blank.
    public init(notices: String?) {
        self.notices = notices
    }

    /// The bundle's notices, or nil when they are missing or unreadable.
    public static func bundled(_ bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public var body: some View {
        Group {
            if let notices {
                ScrollView {
                    Text(verbatim: notices)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                Text("The acknowledgements are missing from this copy of XDict.")
                    .padding()
            }
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}
