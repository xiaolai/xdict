import Foundation

/// **Settings search** (UI30): a concept finds its pane and its row, by the row's name or a common synonym, rows inside
/// a disclosure included. The index is written out, not scraped from the views: a row is searchable because it is named
/// here, and a test holds every pane to having one.
///
/// Matching: every word of the query must occur in the row's name or one of its search aliases, case and diacritics
/// ignored, in any order. Results keep this list's order, which is the sidebar's.
public enum SettingsSearch {
    /// One searchable row, and the place `SettingsRoute.reveal(_:)` takes the reader to.
    public enum Anchor: String, CaseIterable, Hashable, Sendable {
        case dictionaryList, dictionaryImport, wordData
        case readingWidth, readingAccent, readingPhrases, speechVoice
        case history, reviewReminders, syncFolder
        case startup, interfaceLanguage, lookupShortcut, hover, popupAppearance, meaningPaneGap
        case aiSource, aiEntryText, aiLanguage, aiTranslationLanguage, aiPrompt
        case setupBoard
    }

    public struct Item: Identifiable, Sendable {
        public let pane: SettingsTab
        public let anchor: Anchor
        public let title: LocalizedStringResource
        /// Inside a disclosure that starts closed: revealing it opens that disclosure.
        public let isAdvanced: Bool
        /// Search aliases in the supported languages, searched besides the title. Never displayed.
        let keywords: [String]

        public var id: Anchor { anchor }

        init(_ pane: SettingsTab, _ anchor: Anchor, _ title: LocalizedStringResource, advanced: Bool = false,
             keywords: [String]) {
            self.pane = pane
            self.anchor = anchor
            self.title = title
            self.isAdvanced = advanced
            self.keywords = keywords + SettingsSearch.chineseKeywords[anchor, default: []]
        }
    }

    /// Search metadata, never displayed: common Chinese concepts also work when the interface is in English.
    private static let chineseKeywords: [Anchor: [String]] = [
        .dictionaryList: ["词典", "词库", "排序", "启用", "停用", "删除"],
        .dictionaryImport: ["导入", "添加", "文件", "苹果"],
        .wordData: ["词数据", "同义词", "反义词", "押韵", "词族", "词根", "变形"],
        .readingAccent: ["颜色", "外观"],
        .readingWidth: ["阅读", "宽度", "行长"],
        .readingPhrases: ["词组", "短语", "卡片", "阅读"],
        .speechVoice: ["语音", "朗读", "发音", "声音", "录音"],
        .history: ["历史", "隐私", "阅读记录"],
        .reviewReminders: ["复习", "提醒", "通知", "学习"],
        .syncFolder: ["同步", "文件夹", "隐私", "断开"],
        .startup: ["启动", "登录", "菜单栏", "退出", "程序坞", "图标"],
        .interfaceLanguage: ["界面", "语言", "中文", "英文"],
        .lookupShortcut: ["快捷键", "键盘"],
        .hover: ["悬停", "鼠标", "手势", "屏幕录制"],
        .popupAppearance: ["弹窗", "背景", "玻璃"],
        .meaningPaneGap: ["面板", "间隔", "间距", "右侧"],
        .aiSource: ["人工智能", "模型", "来源", "登录", "本地", "云端"],
        .aiEntryText: ["隐私", "发送", "词条"],
        .aiLanguage: ["回答语言", "中文", "英文"],
        .aiTranslationLanguage: ["翻译", "目标语言", "译文"],
        .aiPrompt: ["提示词", "模板", "高级", "预览", "翻译", "语法"],
        .setupBoard: ["设置", "权限", "辅助功能", "服务", "快捷键"],
    ]

    public static let items: [Item] = [
        Item(.dictionaries, .dictionaryList, "Dictionaries",
             keywords: ["library", "order", "enable", "disable", "remove", "details", "mdx", "mdd"]),
        Item(.dictionaries, .dictionaryImport, "Add Dictionaries",
             keywords: ["import", "add", "mdx", "apple", "files"]),
        Item(.dictionaries, .wordData, "Word data",
             keywords: ["rhymes", "families", "roots", "forms", "synonyms", "antonyms", "pack", "install", "remove"]),
        Item(.readingAndSpeech, .readingAccent, "Accent color",
             keywords: ["reading", "color", "colour", "appearance"]),
        Item(.readingAndSpeech, .readingWidth, "Comfortable reading width",
             keywords: ["reading", "width", "measure", "line", "length", "comfortable"]),
        Item(.readingAndSpeech, .readingPhrases, "Show phrases while reading",
             keywords: ["phrases", "phrase", "reading", "cards", "keep", "study", "privacy", "disable", "hide"]),
        Item(.readingAndSpeech, .speechVoice, "Voice",
             keywords: ["speech", "speak", "pronunciation", "accent", "recordings", "audio", "read", "aloud"]),
        Item(.learning, .history, "Reading History",
             keywords: ["history", "lookups", "record", "privacy", "words", "languages"]),
        Item(.learning, .reviewReminders, "Review Reminders",
             keywords: ["review", "reminders", "notifications", "study"]),
        Item(.learning, .syncFolder, "Sync Folder",
             keywords: ["sync", "folder", "icloud", "devices", "privacy", "disconnect"]),
        Item(.general, .startup, "Startup",
             keywords: ["login", "launch", "start", "menu", "bar", "quit", "dock", "icon"]),
        Item(.general, .interfaceLanguage, "Language",
             keywords: ["language", "interface", "chinese", "english"]),
        Item(.general, .lookupShortcut, "Lookup Shortcut",
             keywords: ["shortcut", "hotkey", "keyboard", "key", "global"]),
        Item(.general, .hover, "Hover",
             keywords: ["hover", "pointer", "mouse", "rest", "time", "gesture", "screen", "recording", "never"]),
        Item(.general, .popupAppearance, "Lookup popup",
             keywords: ["popup", "panel", "appearance", "dark", "light", "glass", "background"]),
        Item(.general, .meaningPaneGap, "Answer Pane",
             keywords: ["pane", "panel", "gap", "space", "margin", "separation", "right", "width", "animation",
                        "opening", "shortcut", "keys", "toggle", "show", "hide"]),
        Item(.ai, .aiSource, "Where answers come from",
             keywords: ["ai", "source", "provider", "apple", "local", "cloud", "codex", "claude", "endpoint", "model",
                        "key", "sign", "in"]),
        Item(.ai, .aiEntryText, "Send the entry’s text with the question",
             keywords: ["ai", "privacy", "send", "entry", "disclosure"]),
        Item(.ai, .aiLanguage, "Answer language",
             keywords: ["ai", "language", "chinese", "english"]),
        Item(.ai, .aiTranslationLanguage, "Translate into",
             keywords: ["translation", "translate", "target", "language", "sentence"]),
        Item(.ai, .aiPrompt, "Customize the Prompt", advanced: true,
             keywords: ["ai", "prompt", "template", "wording", "advanced", "preview", "translation", "translate",
                        "grammar"]),
        Item(.setup, .setupBoard, "Setup",
             keywords: ["setup", "permissions", "accessibility", "screen", "recording", "shortcut", "services",
                        "spotlight", "readiness"]),
    ]

    /// The rows matching `query`, in sidebar order; none for an empty query.
    public static func results(_ query: String) -> [Item] {
        let wanted = words(query)
        guard !wanted.isEmpty else { return [] }
        return items.filter { item in
            matches(query, title: String(localized: item.title), keywords: item.keywords)
        }
    }

    /// Match the displayed label as well as aliases; factored so localized compounds are tested directly.
    static func matches(_ query: String, title: String, keywords: [String]) -> Bool {
        let wanted = words(query)
        let have = words(title) + keywords.flatMap(words)
        return !wanted.isEmpty && wanted.allSatisfy { word in
            // Chinese labels have no word breaks. ASCII aliases retain word-prefix matching: “ai” must not find “details”.
            let compound = word.unicodeScalars.contains { !$0.isASCII }
            return have.contains { compound ? $0.contains(word) : $0.hasPrefix(word) }
        }
    }

    /// Whether `query` holds a word to search for; spaces and punctuation alone are no search.
    public static func isSearching(_ query: String) -> Bool { !words(query).isEmpty }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

extension SettingsTab {
    /// The detail's title (UI31): the sidebar's name, one source for both.
    public var paneTitle: LocalizedStringResource { title }
}
