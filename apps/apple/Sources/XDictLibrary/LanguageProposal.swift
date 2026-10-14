import Foundation

/// The languages a reader searches a dictionary in and reads its explanations in, as BCP 47 codes (`en`, `zh-Hans`).
public struct LanguagePair: Codable, Hashable, Sendable {
    public var search: String?
    public var explanation: String?

    public init(search: String?, explanation: String?) {
        self.search = search
        self.explanation = explanation
    }
}

/// How sure a proposal is.
public enum LanguageBasis: String, Codable, Hashable, Sendable {
    /// The file name says so in so many words (`英汉`, `En-Cn`): taken without asking.
    case stated
    /// The file name's script suggests it: proposed, and asked.
    case guessed
    /// Nothing to go on: asked, with no proposal.
    case unknown
    /// The reader chose it.
    case reader
}

/// **A dictionary's languages, proposed from its file name** (L3: "ask when uncertain … avoid confident inference from
/// title"). Only a name that states its pair in so many words — a curated list of Chinese and Japanese pair words, or
/// two language names joined by a dash — is taken without asking. Otherwise the script of the name is a guess the
/// reader is asked to confirm, and a name with no letters proposes nothing. The header's title is never read: it is
/// where editors leave placeholders and marketing.
public struct LanguageProposal: Hashable, Sendable {
    public let pair: LanguagePair
    public let basis: LanguageBasis

    public var needsAsking: Bool { basis != .stated && basis != .reader }

    public init(pair: LanguagePair, basis: LanguageBasis) {
        self.pair = pair
        self.basis = basis
    }

    public static func from(fileName: String) -> LanguageProposal {
        let name = fileName.lowercased().hasSuffix(".mdx") || fileName.lowercased().hasSuffix(".mdd")
            ? String(fileName.dropLast(4)) : fileName
        let chinese = Script.chinese(in: name)
        for (word, pair) in pairWords where name.contains(word) {
            return LanguageProposal(pair: LanguagePair(search: pair.0.code(chinese), explanation: pair.1.code(chinese)),
                                    basis: .stated)
        }
        if let pair = latinPair(in: name) {
            return LanguageProposal(pair: LanguagePair(search: pair.0.code(chinese), explanation: pair.1.code(chinese)),
                                    basis: .stated)
        }
        guard let guessed = Script.dominant(in: name) else {
            return LanguageProposal(pair: LanguagePair(search: nil, explanation: nil), basis: .unknown)
        }
        let code = guessed.code(chinese)
        return LanguageProposal(pair: LanguagePair(search: code, explanation: code), basis: .guessed)
    }

    // MARK: - What a name may state

    /// A language as a name names it; Chinese takes its script from the name (`Script.chinese`).
    enum Language: Hashable {
        case english, chinese, japanese, korean, french, german, spanish, russian

        func code(_ chinese: String) -> String {
            switch self {
            case .english: "en"
            case .chinese: chinese
            case .japanese: "ja"
            case .korean: "ko"
            case .french: "fr"
            case .german: "de"
            case .spanish: "es"
            case .russian: "ru"
            }
        }
    }

    /// Words that state a pair, search language first. Curated rather than composed from single characters: `中华`,
    /// `日报` or `西汉` would read as pairs if any two language characters counted.
    static let pairWords: [(String, (Language, Language))] = [
        ("英汉", (.english, .chinese)), ("英漢", (.english, .chinese)), ("英中", (.english, .chinese)),
        ("英华", (.english, .chinese)), ("英華", (.english, .chinese)),
        ("汉英", (.chinese, .english)), ("漢英", (.chinese, .english)), ("中英", (.chinese, .english)),
        ("华英", (.chinese, .english)), ("華英", (.chinese, .english)),
        ("英英", (.english, .english)), ("汉汉", (.chinese, .chinese)),
        ("英和", (.english, .japanese)), ("英日", (.english, .japanese)),
        ("和英", (.japanese, .english)), ("日英", (.japanese, .english)),
        ("日汉", (.japanese, .chinese)), ("日漢", (.japanese, .chinese)),
        ("汉日", (.chinese, .japanese)), ("漢日", (.chinese, .japanese)),
        ("英韩", (.english, .korean)), ("英韓", (.english, .korean)), ("韩英", (.korean, .english)), ("韓英", (.korean, .english)),
        ("法汉", (.french, .chinese)), ("法漢", (.french, .chinese)), ("汉法", (.chinese, .french)), ("漢法", (.chinese, .french)),
        ("德汉", (.german, .chinese)), ("德漢", (.german, .chinese)), ("汉德", (.chinese, .german)), ("漢德", (.chinese, .german)),
        ("俄汉", (.russian, .chinese)), ("俄漢", (.russian, .chinese)), ("汉俄", (.chinese, .russian)), ("漢俄", (.chinese, .russian)),
    ]

    /// Latin names of languages, as dictionary files abbreviate them.
    static let latinNames: [String: Language] = [
        "en": .english, "eng": .english, "english": .english,
        "cn": .chinese, "zh": .chinese, "chs": .chinese, "cht": .chinese, "chinese": .chinese,
        "ja": .japanese, "jp": .japanese, "jpn": .japanese, "japanese": .japanese,
        "ko": .korean, "kor": .korean, "korean": .korean,
        "fr": .french, "fre": .french, "french": .french,
        "de": .german, "ger": .german, "german": .german,
        "es": .spanish, "spa": .spanish, "spanish": .spanish,
        "ru": .russian, "rus": .russian, "russian": .russian,
    ]

    /// Two Latin language names joined by `-`, `_`, `>` or `→`, each a whole word: `En-Cn`, `English-Chinese`.
    static func latinPair(in name: String) -> (Language, Language)? {
        let words = name.lowercased().split { !$0.isLetter && !"-_>→".contains($0) }
        for word in words {
            let parts = word.split { "-_>→".contains($0) }.map(String.init)
            guard parts.count == 2, let first = parts.first, let last = parts.last,
                  let from = latinNames[first], let to = latinNames[last] else { continue }
            return (from, to)
        }
        return nil
    }

    /// What a name's letters suggest.
    enum Script {
        /// Characters written only in traditional Chinese, and only in simplified, among those dictionary names use.
        static let traditional = Set("漢華詞語辭雙學體國東書譯讀韓現實廣電語")
        static let simplified = Set("汉华词语辞双学体国东书译读韩现实广电语")

        /// `zh-Hant` when the name is written in traditional characters, else `zh-Hans`.
        static func chinese(in name: String) -> String {
            let hant = name.filter(traditional.contains).count, hans = name.filter(simplified.contains).count
            return hant > hans ? "zh-Hant" : "zh-Hans"
        }

        /// The language a name's script suggests, or nil when it has no letters.
        static func dominant(in name: String) -> Language? {
            var kana = 0, hangul = 0, han = 0, cyrillic = 0, latin = 0
            for scalar in name.unicodeScalars {
                switch scalar.value {
                case 0x3040...0x30FF: kana += 1
                case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
                case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
                case 0x0400...0x04FF: cyrillic += 1
                case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
                default: break
                }
            }
            if kana > 0 { return .japanese }
            if hangul > 0 { return .korean }
            if han > 0 { return .chinese }
            if cyrillic > 0 { return .russian }
            if latin > 0 { return .english }
            return nil
        }
    }
}
