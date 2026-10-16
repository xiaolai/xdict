import Foundation

/// **XDict's phonetic faces** (owner, 2026-10-16; the comparison in `dev-docs/artifacts/reading-frame/ipa-font/`): Noto
/// Sans v2.015 in the default Sans reading style, Charis 7.000 in Serif, four styles each, shipped unmodified with their
/// SIL Open Font License notices in the bundle's `Resources/Fonts`. The entry view loads them from there through its
/// own scheme (`xdict://d/font/<file>`), never from a network, under family names no dictionary means, so a
/// dictionary's own `@font-face` of "Charis" or "Noto Sans" cannot stand in for them.
public enum EntryFonts {
    public struct Face: Sendable, Equatable {
        public let family: String
        public let file: String
        public let weight: Int
        public let italic: Bool
    }

    public static let sans = "XDict Phonetic Sans"
    public static let serif = "XDict Phonetic Serif"

    public static let faces: [Face] = [(sans, "NotoSans"), (serif, "Charis")].flatMap { family, stem in
        [("Regular", 400, false), ("Italic", 400, true), ("Bold", 700, false), ("BoldItalic", 700, true)].map {
            Face(family: family, file: "\(stem)-\($0.0).ttf", weight: $0.1, italic: $0.2)
        }
    }

    /// The only names the `font/` route answers.
    public static let files: Set<String> = Set(faces.map(\.file))

    /// Where the running app keeps them: its bundle's `Resources/Fonts` (the development lab's bundle carries a copy).
    public static var bundled: URL? { Bundle.main.resourceURL?.appending(path: "Fonts", directoryHint: .isDirectory) }

    /// The `@font-face` rules, one per file. The frame's sheets come last in the head, so even a dictionary that
    /// declares one of these family names is overruled by these rules.
    static var fontFaceCSS: String {
        faces.map { face in
            #"@font-face{font-family:"\#(face.family)";src:url("\#(EntryRoutes.base)font/\#(face.file)") format("truetype");"#
                + "font-weight:\(face.weight);font-style:\(face.italic ? "italic" : "normal")}"
        }.joined()
    }
}
