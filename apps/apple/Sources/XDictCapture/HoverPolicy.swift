import Foundation

/// **How the reader asks** — the gesture, which is a separate question from which key it uses.
///
/// Holding is a weak statement of intent, because every modifier already means something: ⌥ is
/// Meta in a terminal, types special characters, and modifies clicks and drags. A reader holding
/// it for any of those, with the pointer at rest over text, gets a capture they did not ask for.
///
/// **Tap-once is deliberately not offered.** A bare modifier is abandoned constantly — pressed,
/// then thought better of, then released — and that cannot be told from a deliberate tap without
/// waiting to see whether a chord follows. It would fire more often than holding does, which is
/// the opposite of why the gesture exists.
public enum HoverGesture: String, Codable, Sendable, CaseIterable {
    /// Hold the key while the pointer rests. The shipped default.
    case hold
    /// Tap the key twice, quickly. The key is released by the time the capture runs.
    case doubleTap

    /// What the reader does, shown with the key they chose: `⌥` against `⌥⌥`.
    public func label(_ modifier: HoverModifier) -> String {
        switch self {
        case .hold: modifier.symbol
        case .doubleTap: modifier.symbol + modifier.symbol
        }
    }
}

/// Two presses of one key, close enough together, **with nothing in between**.
///
/// A value rather than a timer: it is handed each event and answers whether that press completed
/// a double-tap, which makes the whole rule testable without a clock or a keyboard.
public struct TapCounter: Sendable {
    /// **How long the second press has to arrive.** Long enough not to demand dexterity, short
    /// enough that two unrelated presses of a key as busy as ⌥ rarely fall inside it.
    public static let window: TimeInterval = 0.4

    private var first: TimeInterval?

    public init() {}

    /// Whether this press completed a double-tap.
    ///
    /// **Times come from the events themselves**, not from a clock read when the callback runs.
    /// Global event monitors are delivered asynchronously, so `NSEvent.modifierFlags` and "now"
    /// describe when this process got around to looking rather than when the reader pressed the
    /// key — which mistimes the window under load, exactly when callbacks are late.
    ///
    /// **A completed tap resets the count**, so a third press begins a new pair rather than
    /// completing a second. Without that, a key held down long enough to auto-repeat — or a
    /// reader tapping three times — would fire a capture on every press after the first.
    public mutating func pressed(at instant: TimeInterval) -> Bool {
        if let first, instant - first <= Self.window, instant >= first {
            self.first = nil
            return true
        }
        first = instant
        return false
    }

    /// **Anything else the reader did cancels the pair**, and this is what makes the gesture mean
    /// something. Watching modifier transitions alone, `⌥←` twice in quick succession is two
    /// presses of ⌥ inside the window — so is `⌘C` then `⌘V` — and the reader gets a capture for
    /// editing text. That is precisely the accidental firing the gesture exists to remove, so
    /// without this the feature argues against itself.
    public mutating func invalidate() { first = nil }
}

/// **The whole of the gesture rule, as a value.** Events in, "did the reader just ask" out.
///
/// It exists because the rule was spread across a watcher that reads AppKit and the clock
/// directly, so the only checks possible on it were greps of the source — which cannot see event
/// ordering, and did not see that a chord between two presses still completed a pair.
public struct GestureRecogniser: Sendable {
    /// What the recogniser is told. Everything that is not a modifier change is `otherInput`:
    /// which key or button it was does not matter, only that the reader did something else.
    public enum Input: Sendable, Equatable {
        /// The modifiers now held, and when the event says so.
        case modifiers(Set<HoverModifier>, at: TimeInterval)
        case otherInput
    }

    private var taps = TapCounter()
    private var wasHeld = false

    public init() {}

    /// Whether this input completed the reader's gesture.
    ///
    /// **A chord is not a tap.** Holding ⌥ and pressing ⌘ leaves ⌥ down, so no press is seen —
    /// but releasing both and pressing ⌥ again would otherwise complete a pair made of two
    /// *shortcut* presses. Any other modifier joining the set cancels, which is the same rule
    /// `otherInput` applies to keys and buttons, extended to the only input that arrives as a
    /// modifier change.
    public mutating func saw(
        _ input: Input, gesture: HoverGesture, modifier: HoverModifier
    ) -> Bool {
        switch input {
        case .otherInput:
            taps.invalidate()
            return false
        case .modifiers(let held, let instant):
            let isHeld = held.contains(modifier)
            defer { wasHeld = isHeld }
            if held.subtracting([modifier]).isEmpty == false { taps.invalidate(); return false }
            guard gesture == .doubleTap, isHeld, !wasHeld else { return false }
            return taps.pressed(at: instant)
        }
    }

    /// **State does not outlive the watching.** Left set, a modifier released while stopped makes
    /// the first press after a restart invisible, and a half-finished pair from minutes ago can
    /// complete against an unrelated press.
    public mutating func reset() {
        taps = TapCounter()
        wasHeld = false
    }
}

/// The key the reader uses to ask, whether they hold it or tap it — see `HoverGesture`, which is
/// the other half of the question.
///
/// Hover is **opt-in per capture, not per session** (XiaolaiDict's A4): without this, the
/// pointer resting anywhere is a capture, and the reader cannot read a page without being helped.
///
/// There is no "none" case on purpose — a hover with no key is the design this exists to
/// prevent, and making it unrepresentable is cheaper than remembering not to configure it.
public enum HoverModifier: String, Codable, Sendable, CaseIterable {
    case option
    case control
    case command
    case shift

    /// The key's own symbol, for a label that sits beside a shortcut. XiaolaiDict's menu carried "⌥" as a
    /// literal, which was right only while the modifier could not be changed — a label that names
    /// the wrong key is worse than no label, because the reader holds it and nothing happens.
    ///
    /// A `switch` rather than a dictionary: a case added later fails to compile here instead of
    /// silently returning an empty string into the menu.
    public var symbol: String {
        switch self {
        case .option: "\u{2325}"
        case .control: "\u{2303}"
        case .command: "\u{2318}"
        case .shift: "\u{21E7}"
        }
    }

}

/// Why a hover did not fire. Every refusal is nameable, because "the popup did not appear" with no
/// reason is indistinguishable from a bug.
public enum HoverRefusal: String, Sendable, Equatable, CaseIterable {
    /// The modifier is not held. The ordinary case, and not a problem.
    case modifierNotHeld
    /// The reader asked for the double-tap gesture and has not tapped.
    case notTapped
    /// This app is excluded — a password manager, a terminal (A3).
    case excludedApp
    /// This site is excluded (A3).
    case excludedSite
    /// The reader asked capture to stop for a while (A5).
    case paused
    /// The pointer has not settled yet. Debouncing is non-negotiable (design note §8).
    case stillMoving
    /// The pointer has not left the word last captured, so there is nothing new to say.
    case samePlace
    /// A capture is already running. Two simultaneous `SCScreenshotManager` captures deadlock —
    /// measured 6 times out of 6 — so a second one is refused rather than started.
    case captureInFlight
    /// The word is written in a script the consumer did not allow (`HoverPolicy.allowedScripts`).
    case scriptNotAllowed
    /// The reader moved on while the capture was running. The capture itself cannot be stopped —
    /// it is a detached task and a `SCScreenshotManager` call that does not honour cancellation —
    /// so what is refused is *accepting its answer*, which is the part that would otherwise deliver
    /// a result and remember a word for a hover nobody was waiting for.
    case cancelled
    /// A newer request replaced this one before its word could be shown — another tap, or a request
    /// the reader made by another trigger while this one was still being read.
    case superseded

    // **No sentence here** (ADR-0014 decision 4): the consumer words each refusal; this target holds kinds only.
}

public enum HoverDecision: Sendable, Equatable {
    case look
    case stayQuiet(HoverRefusal)
}

/// What could be said about the site under the pointer — **three-valued, because two of the
/// answers are not the same "no host".** Text that is not a web page has no site to exclude; a page
/// whose address could not be read might be any site at all, and an exclusion is a promise about
/// every one of them.
public enum HostReading: Sendable, Equatable {
    /// The page's host.
    case known(String)
    /// Not web content: no page, so no site.
    case notWebContent
    /// It may be a page, and its address could not be read.
    case unreadable
}

/// Where the pointer is, in terms a decision can be made about.
public struct HoverSite: Sendable, Equatable {
    public let bundleID: String?
    /// The site under the pointer, where it has been asked.
    public let host: HostReading
    /// Which word the pointer is over, if the capture already knows — used only to tell "the same
    /// word again" from "a new word".
    public let wordKey: String?

    public init(bundleID: String?, reading host: HostReading = .notWebContent, wordKey: String? = nil) {
        self.bundleID = bundleID
        self.host = host
        self.wordKey = wordKey
    }

}

/// Whether a hover may fire. All three gates are P0 in XiaolaiDict's feature list, and all three have to
/// exist **before** any capture does: the first hover that fires in a password field is already
/// the problem they prevent.
public struct HoverPolicy: Sendable, Equatable, Codable {
    /// Held before the pointer does anything (A4).
    public var modifier: HoverModifier
    /// Apps capture never reads (A3). Ships non-empty, and for the same reason the place
    /// exclusions do: a popup in a password field or a terminal is worse than no popup.
    public var excludedApps: Set<String>
    /// Sites capture never reads (A3), by host — as stored: a typed name, or an address saved before hosts were reduced.
    public var excludedHosts: Set<String> {
        didSet { parsedHosts = Self.parsed(excludedHosts) }
    }
    /// **`excludedHosts` read as hosts, once**, when the list is set or decoded — never per decision: `refuses` runs on
    /// every hover and every selection read (verifier, 2026-10-19). Derived, never stored (`CodingKeys`).
    private var parsedHosts: Set<String>
    /// How the reader asks for a capture. `.hold` is what shipped and stays the default.
    public var gesture: HoverGesture
    /// **Where hover reads the text** (owner, 2026-10-19): Accessibility first and the screen where it finds no word, or
    /// the screen only. `.automatic` is what shipped and stays the default.
    public var readingMode: ReadingMode = .automatic
    /// How long the pointer must be still. Debouncing is non-negotiable.
    public var settleMilliseconds: Int
    /// **The scripts a captured word may be written in, handed in by the consumer** — nil or empty filters nothing.
    /// Capture's own filter, not a setting moved from XiaolaiDict (ADR-0014 decision 10): no default here, since the
    /// consumer derives it (from the enabled dictionaries' languages, plan-capture WI-3).
    ///
    /// **Scripts and not languages, because only one of the two is decidable here.** A single word
    /// carries far too little for `NLLanguageRecognizer` to separate English from German (XiaolaiDict
    /// ADR-0015). The script a word is written in is a property of its characters, and
    /// `CaptureScript.dominant` reads it exactly.
    public var allowedScripts: Set<CaptureScript>?

    /// The rests the reader can choose between, named.
    ///
    /// A named list rather than a free slider, for the reason the text-size picker is one: every
    /// value here is a rest the hover path has been used at, and a free number lets a reader set
    /// 20 ms and conclude XDict is broken when it fires at every word they pass over.
    ///
    /// **A case per rest, and no name here.** Each carried an English `name` — "Quick",
    /// "Standard" — which the settings picker drew verbatim, so four labels were in no catalog and
    /// no translator ever saw them. This module has no view layer and may hold no display text;
    /// `HoverLabels` in the UI module names them, and switches over these cases so a rest added
    /// here cannot go unnamed there.
    public enum Settle: Int, Sendable, Equatable, Identifiable, CaseIterable {
        case quick = 120
        case standard = 180
        case relaxed = 300
        case patient = 500

        public var milliseconds: Int { rawValue }
        public var id: Int { rawValue }
    }

    public static let settleChoices: [Settle] = Settle.allCases

    /// **Where hover reads the text.** No name here, as for `Settle`: `HoverSentences` words each case.
    public enum ReadingMode: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        /// Accessibility first — the text the app shares — and the screen where it finds no word.
        case automatic
        /// The screen only (Vision): Accessibility is never asked, for any app or for XDict's own windows.
        case screenOnly

        public var id: String { rawValue }
    }

    /// **Safety, not taste.** Capture always takes the sentence a word sits in, and in a password
    /// manager the whole surface is secrets, which is what makes this a rule and not a preference —
    /// and why it is the only thing shipped excluded. Capture's own list (ADR-0014 decision 10).
    public static let defaultExcludedApps: Set<String> = CaptureExclusions.passwordManagers

    /// Terminals — a named set, and **not excluded by default**.
    ///
    /// They shipped excluded on the reasoning that a popup over a half-typed command is worse than
    /// useless and that terminal content is often not prose. Both are weaker than they look. The
    /// screen-word spike measured hover working in Ghostty (finding 12: "a terminal exposes no text
    /// through Accessibility — OCR is the only path there"), so the exclusion removed something
    /// demonstrated to work; and `HoverModifier` has no "none" case, so hover only fires when the
    /// reader deliberately holds the modifier and rests. It cannot land on a half-typed command by
    /// accident. Whether the content is prose is the reader's business, not the policy's — people
    /// read prose in terminals.
    ///
    /// Kept as a set so a reader who wants the old behaviour can have it in one line rather than by
    /// enumerating six bundle identifiers. **That one line is the whole reason it is `public` and
    /// the whole reason nothing calls it** — being unreferenced is the state it is meant to be in,
    /// and `terminalsRemainANamedSetAReaderCanExclude` is what proves the line still works.
    public static let terminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
    ]

    public static let shipped = HoverPolicy(
        modifier: .option, excludedApps: defaultExcludedApps, excludedHosts: [],
        settleMilliseconds: 180)

    public init(
        modifier: HoverModifier, excludedApps: Set<String>, excludedHosts: Set<String>,
        settleMilliseconds: Int, allowedScripts: Set<CaptureScript>? = nil,
        gesture: HoverGesture = .hold
    ) {
        self.modifier = modifier
        self.excludedApps = excludedApps
        self.excludedHosts = excludedHosts
        parsedHosts = Self.parsed(excludedHosts)
        self.settleMilliseconds = settleMilliseconds
        self.allowedScripts = allowedScripts
        self.gesture = gesture
    }

    /// **Decoded with a default, because the policy is stored as one blob.** A value written
    /// before a field existed carries no such key, and a synthesised decoder would throw on it —
    /// which `HoverPolicyStore.load` turns into `.shipped`, silently discarding every app and site
    /// the reader had excluded. That would read as the exclusions resetting themselves one launch
    /// after an update, with nothing said. Every field a later version adds needs this treatment.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modifier = try values.decode(HoverModifier.self, forKey: .modifier)
        excludedApps = try values.decode(Set<String>.self, forKey: .excludedApps)
        excludedHosts = try values.decode(Set<String>.self, forKey: .excludedHosts)
        parsedHosts = Self.parsed(excludedHosts)
        settleMilliseconds = try values.decode(Int.self, forKey: .settleMilliseconds)
        allowedScripts = try values.decodeIfPresent(Set<CaptureScript>.self, forKey: .allowedScripts)
        // Added after readers already had a stored policy. The synthesised decoder throws on a
        // blob written before a field existed, and `HoverPolicyStore.load` turns a throw into
        // `.shipped` — silently discarding every exclusion the reader had set.
        gesture = try values.decodeIfPresent(HoverGesture.self, forKey: .gesture) ?? .hold
        // **Any value this version cannot read is Automatic, and the rest stands**: a mode a later version writes, or a
        // value of another type, must not make the whole blob fail and reset the reader's exclusions.
        let storedMode = (try? values.decodeIfPresent(String.self, forKey: .readingMode)) ?? nil
        readingMode = storedMode.flatMap(ReadingMode.init(rawValue:)) ?? .automatic
    }

    /// The order is deliberate: the cheapest and commonest refusal first, so the ordinary case —
    /// the reader is just reading — costs one comparison and never touches Accessibility.
    /// `tappedTwice` says a double-tap of the hover modifier just completed. **It has no default**
    /// — a caller that forgets it would silently make the double-tap gesture unreachable, and a
    /// parameter nobody supplies is invisible to every unit test that exercises the value directly.
    public func decide(
        at site: HoverSite, modifiersHeld: Set<HoverModifier>, tappedTwice: Bool,
        pointerStillFor: Duration, pausedUntil: Date?, lastLookedUp: String?,
        captureInFlight: Bool, now: Date
    ) -> HoverDecision {
        // **The gesture decides whether the reader asked; everything below decides whether the
        // answer may be given.** A tap does not require the key to still be down — requiring it
        // would make the gesture a hold with extra steps.
        switch gesture {
        case .hold:
            guard modifiersHeld.contains(modifier) else { return .stayQuiet(.modifierNotHeld) }
        case .doubleTap:
            guard tappedTwice else { return .stayQuiet(.notTapped) }
        }
        if let pausedUntil, now < pausedUntil { return .stayQuiet(.paused) }
        if let bundleID = site.bundleID, excludes(app: bundleID) { return .stayQuiet(.excludedApp) }
        if refuses(site.host) { return .stayQuiet(.excludedSite) }
        if captureInFlight { return .stayQuiet(.captureInFlight) }
        guard pointerStillFor >= .milliseconds(settleMilliseconds) else { return .stayQuiet(.stillMoving) }
        if let wordKey = site.wordKey, wordKey == lastLookedUp { return .stayQuiet(.samePlace) }
        return .look
    }

    /// Whether a captured word is written in an allowed script.
    ///
    /// **Asked after the word has been read, never inside `decide`.** The gate runs before any
    /// text exists — that is what makes the ordinary refusal cost one set comparison — so the
    /// script cannot be one of its inputs. This is the second line, beside the repeat check, and
    /// what it saves is everything downstream of capture.
    ///
    /// **Text in no script at all is allowed.** A capture of `42`, of punctuation, or of a
    /// script this does not enumerate names nothing — and refusing there would make the filter
    /// quietly wider than it was set, in precisely the captures OCR is least sure of.
    public func allows(_ text: String) -> Bool {
        guard let allowed = allowedScripts, !allowed.isEmpty else { return true }
        guard let script = CaptureScript.dominant(in: text) else { return true }
        return allowed.contains(script)
    }

    /// Whether `bundleID` is an app hover never reads — the one predicate the gate and
    /// `CaptureAuthorization` both ask.
    public func excludes(app bundleID: String) -> Bool { excludedApps.contains(bundleID) }

    /// Whether the site under the pointer is excluded. **An unreadable address is refused while the
    /// list has anything in it** — the reader asked for those sites to be left alone, and a page
    /// that cannot be named might be one of them. With an empty list nothing is refused, so a
    /// reader who excluded nothing pays nothing for this.
    public func refuses(_ host: HostReading) -> Bool {
        switch host {
        case .known(let name): Self.matches(name, parsedHosts)
        case .notWebContent: false
        case .unreadable: !excludedHosts.isEmpty
        }
    }

    /// **Whether a window read only as pixels may hold a page that cannot be named** (Screen Only; verifier, 2026-10-19:
    /// refusing every window while a site was listed silenced hover in every app). Without Accessibility no page is
    /// named, so while any site is listed (`refuses(.unreadable)`) a known browser's window is refused, and so is a
    /// window whose owner cannot be named; every other app is read. **A gap, stated**: web content another app embeds (a
    /// mail message, an Electron app's page) is read as that app's pixels, since nothing here can tell it is a page.
    public func refusesUnnamedPage(in bundleID: String?) -> Bool {
        guard refuses(.unreadable) else { return false }
        guard let bundleID else { return true }
        return Self.isBrowser(bundleID)
    }

    /// **A known browser, or one of its web apps**: a listed identifier, a listed browser's `.app.` family (Chrome's,
    /// Edge's, Brave's web apps and any Chromium browser's), or Safari's web apps (`com.apple.Safari.WebApp.`). A name
    /// that only begins like a browser's (`com.google.Chromecast`) is not one.
    public static func isBrowser(_ bundleID: String) -> Bool {
        if knownBrowsers.contains(bundleID) { return true }
        if knownBrowserPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        return knownBrowsers.contains { bundleID.hasPrefix($0 + ".app.") }
    }

    /// Web-app families whose prefix is not a listed browser's `.app.` one.
    public static let knownBrowserPrefixes: [String] = ["com.apple.Safari.WebApp."]

    /// The web browsers Screen Only refuses while a site is listed, by bundle identifier: each release channel its own.
    /// **Not every identifier was read from an installed bundle** (2026-10-20: only Safari, Chrome and Firefox are installed
    /// where this was written); a browser named wrongly or not at all is read as any app's pixels — fail-open, and the
    /// Settings caption names browsers, not this list.
    public static let knownBrowsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX", "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS", "com.duckduckgo.macos.browser", "app.zen-browser.zen",
        "org.torproject.torbrowser", "net.waterfox.waterfox", "org.mozilla.librewolf", "io.gitlab.librewolf-community",
        "com.sigmaos.sigmaos.macos", "ai.perplexity.comet", "com.openai.atlas", "com.naver.Whale",
        "ru.yandex.desktop.yandex-browser", "one.ablaze.floorp", "org.chromium.Thorium", "io.wavebox.wavebox",
        "com.pushplaylabs.sidekick", "net.mullvad.mullvadbrowser", "com.electron.min",
    ]

    /// The host a reader means by what they typed — **a name, or a pasted address reduced to its
    /// host** — or nil where neither can be read. A pasted `https://docs.example.com/page` used to be
    /// stored whole and could never match a page's host, so the exclusion silently covered nothing.
    public static func siteHost(fromTyped typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Read as an address either way, so a pasted URL and a typed `example.com:443` both give the
        // host alone — a page reports no port. An IPv6 literal is not a bare address, and is kept.
        let asAddress = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        let candidate = URL(string: asAddress)?.host(percentEncoded: false) ?? trimmed
        let host = normalisedHost(candidate.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        // An address of either family — names (after IDNA, so ASCII), or an IPv6 literal.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:")
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains), !host.hasPrefix("."),
              !host.contains(".."), host.split(separator: ".").allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") })
        else { return nil }
        // **A colon left in the host is an IPv6 literal, or the input was malformed** — a port was
        // already taken off above. Stored as typed, `example.com:abc` was an exclusion no page's host
        // could ever equal, so the system's own parser decides.
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
            return host
        }
        // **Within DNS's limits**: a name of at most 253 characters, each label at most 63 (RFC 1035) — a longer one is
        // no host any page reports, and an exclusion of it covers nothing.
        guard host.utf8.count <= maximumHostLength,
              host.split(separator: ".").allSatisfy({ $0.utf8.count <= maximumLabelLength })
        else { return nil }
        return host
    }

    /// The longest host name, in characters (RFC 1035, its dotted form).
    public static let maximumHostLength = 253
    /// The longest label of a host name, in characters (RFC 1035).
    public static let maximumLabelLength = 63

    /// Host names are case-insensitive and may carry a trailing root dot, so `EXAMPLE.COM.` and
    /// `example.com` are the same site. Compared without normalising, an exclusion the reader set
    /// is bypassed by the capitalisation of a link they clicked — which is not an exclusion.
    ///
    /// **In its IDNA form**: `bücher.de` typed by the reader is `xn--bcher-kva.de` in every address a
    /// page reports, and compared as typed it would never match.
    public static func normalisedHost(_ host: String) -> String {
        var normalised = host.trimmingCharacters(in: .whitespaces).lowercased()
        while normalised.hasSuffix(".") { normalised.removeLast() }
        if !normalised.contains(":"), normalised.unicodeScalars.contains(where: { !$0.isASCII }),
           let ascii = URL(string: "https://\(normalised)")?.host(percentEncoded: false) {
            normalised = ascii.lowercased()
        }
        return normalised
    }

    /// Whether `host` is excluded by `excluded`, matching the name itself or any subdomain of it.
    /// Both sides are normalised, so it does not matter how either was typed.
    static func isExcluded(_ host: String, by excluded: Set<String>) -> Bool {
        matches(host, parsed(excluded))
    }

    /// The stored entries as hosts. **What was stored is read as an address too**: lists saved before `siteHost`
    /// existed can hold whole URLs, and compared as text they matched nothing.
    private static func parsed(_ stored: Set<String>) -> Set<String> {
        Set(stored.map { siteHost(fromTyped: $0) ?? normalisedHost($0) }.filter { !$0.isEmpty })
    }

    /// Whether `host`, or a domain it is under, is one of `hosts` — a set lookup per label, whatever the list's length.
    private static func matches(_ host: String, _ hosts: Set<String>) -> Bool {
        let host = normalisedHost(host)
        guard !host.isEmpty, !hosts.isEmpty else { return false }
        if hosts.contains(host) { return true }
        var rest = Substring(host)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if hosts.contains(String(rest)) { return true }
        }
        return false
    }

    /// The stored fields, and not the parsed hosts, which are derived from them.
    enum CodingKeys: String, CodingKey {
        case modifier, excludedApps, excludedHosts, settleMilliseconds, allowedScripts, gesture, readingMode
    }
}

/// The pause switch: "stop looking things up for an hour", reachable in one click (A5). No surveyed
/// dictionary has one, and the reader sometimes wants to read without being helped.
public struct HoverPause: Sendable, Equatable {
    public static let durations: [Duration] = [.seconds(900), .seconds(3_600), .seconds(28_800)]

    public var until: Date?

    public init(until: Date? = nil) {
        self.until = until
    }

    public func isPaused(at now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    /// **Both components, not just the seconds.** `Duration.components` splits into whole seconds
    /// and attoseconds, and taking the first alone silently truncated: 1.5 s became 1 s and
    /// anything under a second expired the moment it was set. Every duration the menu offers today
    /// is a whole number of seconds, which is what kept it invisible.
    public mutating func pause(for duration: Duration, from now: Date) {
        let parts = duration.components
        until = now.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    public mutating func resume() {
        until = nil
    }

    // **What the menu says about a pause is not here.** `label(at:)` returned the menu's words from
    // this module, which may hold no display text — they were in no string catalog. The app target's
    // `HoverPauseMenu` builds them from `until`, localised, since 2026-10-02.
}
