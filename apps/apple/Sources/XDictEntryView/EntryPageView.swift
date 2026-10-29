import AppKit
import WebKit
import os
import XDictTokens

/// **The divider between two dictionaries** (parity P15; quieter after HIG audit UI25, owner-approved 2026-10-23): a
/// disclosure triangle at the leading edge, the dictionary's name just after it in the secondary label colour and the
/// dictionary-name role (13 pt semibold at actual size, under the headword rather than competing with it), then a
/// hairline in the system's separator colour to the trailing inset. Apple's centred 18 pt name between two grey rules
/// read as a heading that interrupted the entry. A click anywhere on it, VoiceOver's press, or (with full keyboard
/// access) Space or Return collapses or expands that dictionary. Its name, band and triangle follow the one text size,
/// as Apple's do (P15, P29).
/// **In the lookup popover, Apple's compact one** (P41; `popover.png`, `popover.dark.png`): the name leading, as the
/// popover's title is, then a hairline to the trailing inset; no triangle, no collapse, a fixed size.
@MainActor
final class EntryPageDivider: NSView {
    static let height: CGFloat = Tokens.PageDivider.height

    /// The popover's compact divider, in the popover's title-row metrics (`PanelLook`): the name 24 pt in, the system
    /// font at 20 pt in the label colour, a hairline from 8 pt after it to 27 pt from the trailing edge, in a 40 pt
    /// band (an 8 pt gap each side of the 24 pt row).
    enum Popover {
        static let leading: CGFloat = Tokens.Inset.panelLeading
        static let trailing: CGFloat = Tokens.Inset.panelTrailing
        static let height: CGFloat = Tokens.PageDivider.popoverBand
        static let gap: CGFloat = Tokens.PageDivider.popoverGap
    }

    /// The divider at a text size: the name's points, the band's height, the triangle's half-width.
    struct Metrics: Equatable {
        let font: CGFloat
        let height: CGFloat
        let triangle: CGFloat
    }

    static func metrics(zoom: Double) -> Metrics {
        let scale = CGFloat(zoom)
        return Metrics(font: nameFont.pointSize * scale, height: height * scale, triangle: Tokens.PageDivider.triangle * scale)
    }
    /// The name's role at actual size: the one the popover's divider names its dictionaries in (UI25).
    static var nameFont: NSFont { Tokens.TextRole.panelDictionaryName.nsFont }
    /// The name's font at a size: the role's face and weight, the text size's points.
    static func nameFont(size: CGFloat) -> NSFont { NSFont(descriptor: nameFont.fontDescriptor, size: size) ?? nameFont }
    /// The rule: the system's separator, a hairline that marks the boundary without drawing the eye (UI25).
    static var ruleColour: NSColor { Tokens.Colour.separator.nsColor }

    let name: String
    let style: EntryPageStyle
    let label: NSTextField
    private var metrics: Metrics
    private var heightConstraint: NSLayoutConstraint?
    var onToggle: (() -> Void)?
    var collapsed = false {
        didSet {
            needsDisplay = true
            guard style == .window else { return }
            setAccessibilityValue(collapsed ? 0 : 1)
            setAccessibilityExpanded(!collapsed)
        }
    }

    init(name: String, zoom: Double = 1, style: EntryPageStyle = .window) {
        self.name = name
        self.style = style
        label = NSTextField(labelWithString: name)
        metrics = Self.metrics(zoom: zoom)
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityLabel(name)
        setAccessibilityIdentifier("page.divider.\(name)")
        switch style {
        case .window:
            label.font = Self.nameFont(size: metrics.font)
            label.textColor = .secondaryLabelColor
            label.alignment = .natural
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let height = heightAnchor.constraint(equalToConstant: metrics.height)
            heightConstraint = height
            NSLayoutConstraint.activate([
                height,
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.ruleStart),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -(Self.trailing + Self.gap)),
            ])
            setAccessibilityRole(.disclosureTriangle)
            setAccessibilityValue(1)
        case .popover:
            label.font = Tokens.TextRole.panelDictionaryName.nsFont
            label.textColor = .secondaryLabelColor
            label.alignment = .natural
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: Popover.height),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Popover.leading),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                constant: -(Popover.trailing + Popover.gap)),
            ])
            setAccessibilityRole(.staticText)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The band's height as laid out: what the page's height counts.
    var bandHeight: CGFloat { style == .popover ? Popover.height : metrics.height }

    /// The text size changed: the name, the band and the triangle follow it (the popover's stay, as its title does).
    func setZoom(_ zoom: Double) {
        guard style == .window else { return }
        let next = Self.metrics(zoom: zoom)
        guard next != metrics else { return }
        metrics = next
        label.font = Self.nameFont(size: next.font)
        heightConstraint?.constant = next.height
        needsDisplay = true
    }

    /// Apple's geometry, in points from the pane's leading edge: the triangle centred at 29, the name from 45, the rule
    /// from 12 after the name to 16 short of the trailing edge.
    static let triangleCentre: CGFloat = Tokens.PageDivider.triangleCentre
    static let ruleStart: CGFloat = Tokens.PageDivider.ruleStart
    static let trailing: CGFloat = Tokens.PageDivider.trailing
    static let gap: CGFloat = Tokens.PageDivider.gap

    override var isFlipped: Bool { true }

    /// The hairline both title rows draw, from just after the name to the trailing inset (audit round 4, 2026-10-25:
    /// the window and popover branches drew it twice, in two colours that are the same token).
    private func drawRule(from start: CGFloat, to end: CGFloat, at y: CGFloat) {
        guard end > start else { return }
        Self.ruleColour.setStroke()
        let rule = NSBezierPath()
        rule.lineWidth = Tokens.Line.hairline
        rule.move(to: NSPoint(x: start, y: y))
        rule.line(to: NSPoint(x: end, y: y))
        rule.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = (bounds.height / 2).rounded(.down) + 0.5
        if style == .popover {
            drawRule(from: label.frame.maxX + Popover.gap, to: bounds.maxX - Popover.trailing, at: mid)
            return
        }
        drawRule(from: label.frame.maxX + Self.gap, to: bounds.maxX - Self.trailing, at: mid)
        // ▼ expanded, ▶ collapsed, in the label colour at Apple's size (about 11 pt across).
        let c = NSPoint(x: Self.triangleCentre, y: bounds.height / 2), r = metrics.triangle
        let triangle = NSBezierPath()
        if collapsed {
            triangle.move(to: NSPoint(x: c.x - r * 0.8, y: c.y - r))
            triangle.line(to: NSPoint(x: c.x + r * 0.9, y: c.y))
            triangle.line(to: NSPoint(x: c.x - r * 0.8, y: c.y + r))
        } else {
            triangle.move(to: NSPoint(x: c.x - r, y: c.y - r * 0.8))
            triangle.line(to: NSPoint(x: c.x + r, y: c.y - r * 0.8))
            triangle.line(to: NSPoint(x: c.x, y: c.y + r * 0.9))
        }
        triangle.close()
        NSColor.secondaryLabelColor.setFill()
        triangle.fill()
    }

    override func mouseDown(with event: NSEvent) { toggle() }

    /// **Reachable from the keyboard as a disclosure button is** (UI25): with full keyboard access on, Tab can focus it
    /// and Space or Return toggles it; otherwise a click never takes the focus from the entry.
    override var acceptsFirstResponder: Bool { style == .window && NSApp?.isFullKeyboardAccessEnabled == true }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func keyDown(with event: NSEvent) {
        guard style == .window, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "") else {
            super.keyDown(with: event)
            return
        }
        toggle()
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(rect: bounds).fill() }
    override func accessibilityPerformPress() -> Bool {
        guard style == .window else { return false }
        toggle()
        return true
    }

    /// The popover's divider collapses nothing.
    func toggle() {
        guard style == .window else { return }
        onToggle?()
    }
}

/// **The dictionary being read, pinned over the page** (HIG audit UI24): once the current section's own divider has
/// scrolled above the view, its name stays at the page's top, quiet, in the divider's role on the header material, so
/// the reader always knows whose entry they are reading. It is not a control: every click passes to the page under it;
/// Go ▸ Dictionaries on This Page jumps to another.
@MainActor
final class EntryPageSourceLabel: NSVisualEffectView {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        label.font = EntryPageDivider.nameFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Tokens.Space.sm),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Tokens.Space.sm),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Tokens.Space.xs),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Tokens.Space.xs),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("page.current-source")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    /// Shows the name, or hides the label when none is pinned.
    func show(_ name: String?) {
        isHidden = name == nil
        label.stringValue = name ?? ""
        setAccessibilityLabel(name.map { String(localized: EntrySentences.currentDictionary($0)) })
    }

    /// Not a control: the page under it takes every click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// **One dictionary's part of the page**: its divider, and its frame — a pane of its own (`EntryPane`), made when it is
/// first needed, sized to its document so it never scrolls inside.
@MainActor
final class EntryPageSection {
    /// **What the section holds while its frame has no entry in it** (owner, 2026-10-29). A frame keeps its estimated
    /// height until its document lands, so a dictionary that cannot answer leaves a tall blank where its entry belongs —
    /// and if it is the page's first section, with no divider by Apple's rule, nothing on screen names it. The band
    /// therefore says what it is: `loading` until the document arrives, `failed` when the dictionary could not give the
    /// entry at all, which the page retries the next time it is shown.
    enum Standing: Equatable {
        /// No frame has been made for it yet (it is off screen).
        case pending
        /// Its frame exists and its document is on its way.
        case loading
        /// Its document loaded and took its height.
        case shown
        /// The dictionary could not give the entry.
        case failed
    }

    let item: EntryPageItem
    let divider: EntryPageDivider
    /// What the frame's web view sits in, at the document's height.
    let holder = NSView()
    /// The band's sentence while the frame has no entry to show; empty and hidden once the entry is there.
    let notice = NSTextField(wrappingLabelWithString: "")
    private let height: NSLayoutConstraint
    private(set) var pane: EntryPane?
    /// What the band holds now; see [`Standing`].
    private(set) var standing: Standing = .pending
    var collapsed: Bool { didSet { apply() } }
    var hasDivider = true { didSet { apply() } }
    /// The frame's document has loaded at least once, and the frame has taken its height.
    var finished = false
    /// Told when the frame's height changed: the page's height is news to whoever sizes to it (the popover).
    var onHeightChange: (() -> Void)?

    var id: UUID { item.id }
    var name: String { item.name }
    /// Whether the dictionary could not give this entry: the page names the section and retries it when shown again.
    var failed: Bool { standing == .failed }

    init(item: EntryPageItem, collapsed: Bool, zoom: Double = 1, style: EntryPageStyle = .window) {
        self.item = item
        self.collapsed = collapsed
        divider = EntryPageDivider(name: item.name, zoom: zoom, style: style)
        holder.translatesAutoresizingMaskIntoConstraints = false
        height = holder.heightAnchor.constraint(equalToConstant: CGFloat(EntryPagePlan.estimatedHeight))
        height.priority = .required
        height.isActive = true
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.font = Tokens.TextRole.callout.nsFont
        notice.textColor = .secondaryLabelColor
        notice.alignment = .center
        notice.isHidden = true
        holder.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            notice.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            notice.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor, constant: Tokens.Space.xl),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -Tokens.Space.xl),
        ])
        apply()
    }

    /// Says what the band is, or — with no sentence — that it is nothing but the entry: the notice leaves the view.
    func stand(_ standing: Standing, saying sentence: String?) {
        self.standing = standing
        notice.stringValue = sentence ?? ""
        notice.isHidden = sentence == nil
    }

    /// The frame's height in points, as laid out now.
    var frameHeight: Double { Double(height.constant) }

    func setHeight(_ points: Double) {
        let clamped = CGFloat(min(max(points, 1), EntryPage.maximumFrameHeight))
        guard abs(height.constant - clamped) >= 0.5 else { return }
        height.constant = clamped
        // **A frame held at the cap scrolls its own document** (audit round 4, 2026-10-25); one as tall as its document
        // hands the wheel to the page.
        pane?.view.scrollsInternally = clamped >= EntryPage.maximumFrameHeight - 0.5
        onHeightChange?()
    }

    /// What this section adds to the page's height: its divider's band when shown, its frame when expanded.
    var pageHeight: Double {
        (hasDivider ? Double(divider.bandHeight) : 0) + (collapsed ? 0 : frameHeight)
    }

    func attach(_ pane: EntryPane) {
        self.pane = pane
        let view = pane.view
        view.translatesAutoresizingMaskIntoConstraints = false
        view.passesScrollToPage = true
        view.scrollsInternally = frameHeight >= EntryPage.maximumFrameHeight - 0.5
        holder.addSubview(view)
        // **The band's sentence stays on top of the frame** (owner, 2026-10-29): a window-style frame draws its own
        // paper, which would hide a notice underneath it, and the notice is exactly what shows while that paper is empty.
        holder.addSubview(notice, positioned: .above, relativeTo: view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: holder.topAnchor),
            view.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        ])
    }

    func close() {
        pane?.close()
        pane = nil
        divider.removeFromSuperview()
        holder.removeFromSuperview()
    }

    private func apply() {
        divider.collapsed = collapsed
        divider.isHidden = !hasDivider
        holder.isHidden = collapsed
    }
}

/// A view whose origin is its top-left, as a page's is.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// **The All page** (parity P15): every dictionary's entry for the headword, stacked in the reader's order in one
/// scrolling page, each in its own frame. Frames are made for the screen and one screen beyond (`EntryPagePlan`), the
/// rest as the reader scrolls.
@MainActor
final class EntryPage: NSObject, WKScriptMessageHandler {
    /// A frame never grows past this, in points: past it the frame scrolls inside, so a hostile document claiming a
    /// height of millions cannot make a web view that size.
    static let maximumFrameHeight: Double = 200_000
    static let heightHandler = "xdictPageHeight"

    let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private(set) var sections: [EntryPageSection] = []
    private let make: (EntryPageSection) -> Result<EntryPane, EntryRefusal>
    private let preferences: EntryPreferences
    private var zoom: Double
    let style: EntryPageStyle
    /// Told whenever the page's height (`contentHeight`) may have changed: a frame's height, or the sections shown.
    var onContentHeightChanged: (() -> Void)?
    /// Where to land once the frames above it have loaded: a page offset in points.
    private var pendingOffset: Double?
    /// Which presentation a suspended reveal belongs to (audit round 4, 2026-10-25).
    private var pageGeneration = 0
    /// Find across the frames: the query, each section's visible match count, and the current match.
    private var findQuery = ""
    private var findCounts: [Int] = []
    private var findCurrent: (section: Int, match: Int)?
    private var findHidden = 0
    var onRefusal: ((EntryRefusal) -> Void)?
    /// The moment the page was asked for, and when its first frame finished: first paint, for the measurement.
    private(set) var asked = ContinuousClock.now
    private(set) var firstPaint: Duration?

    init(preferences: EntryPreferences, zoom: Double, style: EntryPageStyle = .window,
         make: @escaping (EntryPageSection) -> Result<EntryPane, EntryRefusal>) {
        self.preferences = preferences
        self.zoom = zoom
        self.style = style
        self.make = make
        super.init()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // In the popover the page is the glass: its frames are clear (`EntryPane.page`), and so is the page.
        scroll.drawsBackground = style == .window
        scroll.contentView.drawsBackground = style == .window
        scroll.backgroundColor = Tokens.Colour.entryPage.nsColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: clip)
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification,
                                               object: scroll)
        // The pinned name (UI24), over the page and under its scroller; the popover names every section already.
        if style == .window {
            scroll.addSubview(sourceLabel, positioned: .above, relativeTo: clip)
            NSLayoutConstraint.activate([
                sourceLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                sourceLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: Tokens.Space.xs),
                sourceLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor,
                                                   constant: -2 * EntryPageDivider.ruleStart),
            ])
        }
    }

    var panes: [EntryPane] { sections.compactMap(\.pane) }

    /// **The page's height in points**: every shown divider's band and every expanded frame's height (a frame not yet
    /// made counts at its estimate). What the popover sizes itself to, up to its cap, past which the page scrolls.
    var contentHeight: Double { sections.reduce(0) { $0 + $1.pageHeight } }

    /// A popover's page collapses nothing: its divider has no triangle (Apple's popover), and a dictionary collapsed in
    /// the main window would otherwise be in the popover with no way to open it. The main window's choice is kept.
    private func isCollapsed(_ item: EntryPageItem) -> Bool {
        style == .window && preferences.collapsed(for: item.content.binding.dictionary)
    }

    // MARK: - Showing

    /// Shows `items` in this order: a section whose dictionary, binding and record are unchanged keeps its frame as it
    /// is; the others are made afresh. Returns the first refusal, if a frame could not be made with every layer.
    func show(_ items: [EntryPageItem], landing offset: Double?) -> EntryRefusal? {
        let previous = sections.map { $0.item.identity }
        let old = Dictionary(sections.map { ($0.item.identity, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: Set<ObjectIdentifier> = []
        var next: [EntryPageSection] = []
        for item in items {
            // **A section whose dictionary could not give its entry is not kept** (owner, 2026-10-29): keeping it kept
            // its empty frame for as long as the word stayed on screen, so a dictionary that was still indexing showed a
            // blank band that never healed. A fresh section asks it again, and the answer of this show is the page's.
            if let section = old[item.identity], !kept.contains(ObjectIdentifier(section)), !section.failed {
                kept.insert(ObjectIdentifier(section))
                next.append(section)
            } else {
                next.append(EntryPageSection(item: item, collapsed: isCollapsed(item), zoom: zoom, style: style))
            }
        }
        for section in sections where !kept.contains(ObjectIdentifier(section)) { section.close() }
        if kept.isEmpty {
            asked = .now
            firstPaint = nil
        }
        // **A changed section set invalidates Find** (audit round 4, 2026-10-25): its counts index the old sections, and a
        // removed or reordered dictionary would make Next reach another frame or beyond the array.
        if next.map({ $0.item.identity }) != previous {
            pageGeneration += 1
            findSerial += 1
            clearFindState()
        }
        sections = next
        for (index, section) in next.enumerated() {
            section.hasDivider = Self.divider(at: index, for: section, style: style)
            section.divider.onToggle = { [weak self, weak section] in
                guard let self, let section else { return }
                self.toggle(section)
            }
            section.onHeightChange = { [weak self] in
                self?.onContentHeightChanged?()
                self?.reportSources()
            }
            // A section that has not been asked for its entry yet stands in its band too: it is made on the next
            // `materialize`, but a page shown with the section already on screen never shows blank paper in between.
            if section.standing == .pending {
                section.stand(.pending, saying: String(localized: EntrySentences.pageLoading(section.name)))
            }
        }
        let views = next.flatMap { [$0.divider as NSView, $0.holder] }
        if stack.arrangedSubviews != views {
            for view in stack.arrangedSubviews where !views.contains(view) { stack.removeArrangedSubview(view) }
            for (index, view) in views.enumerated() {
                stack.insertArrangedSubview(view, at: index)
            }
        }
        // **Every presentation states its landing** (audit round 4): an earlier offset must not outlive the page it was
        // asked for, and reused frames already loaded never call `finished()` to consume it.
        pendingOffset = offset
        if offset == nil, kept.isEmpty { scrollTo(0) }
        onContentHeightChanged?()
        let refusal = materialize()
        landIfReady()
        return refusal
    }

    func close() {
        pageGeneration += 1
        findSerial += 1
        clearFindState()
        NotificationCenter.default.removeObserver(self)
        for section in sections { section.close() }
        sections = []
        scroll.removeFromSuperview()
    }

    /// Collapses or expands one dictionary, and keeps the choice for it.
    func toggle(_ section: EntryPageSection) {
        section.collapsed.toggle()
        preferences.setCollapsed(section.collapsed, for: section.item.content.binding.dictionary)
        if let index = sections.firstIndex(where: { $0 === section }) {
            section.hasDivider = Self.divider(at: index, for: section, style: style)
        }
        onContentHeightChanged?()
        if let refusal = materialize() { onRefusal?(refusal) }
    }

    /// Whether a section carries a divider, from the plan and from what the section is now: a frame without an entry
    /// keeps its dictionary's name (owner, 2026-10-29).
    private static func divider(at index: Int, for section: EntryPageSection, style: EntryPageStyle) -> Bool {
        EntryPagePlan.hasDivider(at: index, collapsed: section.collapsed, style: style, failed: section.failed)
    }

    /// **A dictionary that could not give the page its entry** (owner, 2026-10-29): the band says so instead of holding
    /// blank paper, and the section keeps (or regains) its divider, so the page names what is missing even where Apple's
    /// rule would leave the first dictionary unnamed. The next `show` of this page builds a fresh frame for it.
    private func sectionFailed(_ section: EntryPageSection) {
        section.stand(.failed, saying: String(localized: EntrySentences.entryFailed))
        if let index = sections.firstIndex(where: { $0 === section }) {
            section.hasDivider = Self.divider(at: index, for: section, style: style)
        }
        onContentHeightChanged?()
        onFramesChanged?()
        reportSources()
    }

    /// Makes the frames the viewport wants (or every frame, for find); the first refusal stops it.
    @discardableResult
    func materialize(all: Bool = false, including wanted: Int? = nil) -> EntryRefusal? {
        defer { reportSources() }
        document.layoutSubtreeIfNeeded()
        var indices: [Int]
        if all {
            indices = Array(sections.indices)
        } else {
            let tops = sections.map { Double($0.holder.frame.minY) }
            let heights = sections.map(\.frameHeight)
            let visible = scroll.contentView.bounds
            let height = visible.height > 0 ? Double(visible.height) : Double(scroll.frame.height)
            indices = EntryPagePlan.wanted(tops: tops, heights: heights, collapsed: sections.map(\.collapsed),
                                           top: Double(visible.minY), height: max(height, 1)).sorted()
        }
        if let wanted, sections.indices.contains(wanted), !indices.contains(wanted) { indices.append(wanted) }
        for index in indices where sections[index].pane == nil {
            let section = sections[index]
            switch make(section) {
            case .failure(let why): return why
            case .success(let pane):
                section.attach(pane)
                pane.setZoom(zoom)
                pane.view.configuration.userContentController.add(self, contentWorld: EntryPane.world,
                                                                  name: Self.heightHandler)
                pane.view.configuration.userContentController.add(self, contentWorld: EntryPane.world,
                                                                  name: Self.scrollHandler)
                section.stand(.loading, saying: String(localized: EntrySentences.pageLoading(section.name)))
                let reference = section.item.reference
                Task { @MainActor [weak self, weak section] in
                    // **A frame that could not be given its entry says so** (owner, 2026-10-29): `show` answers false
                    // when the dictionary could not produce the entry, and it was discarded — the section kept its
                    // estimated height, blank, forever. It is named instead, and the next show of the page retries it.
                    let shown = await pane.show(reference)
                    guard let self, let section, !shown, section.pane === pane else { return }
                    self.sectionFailed(section)
                }
            }
        }
        onFramesChanged?()
        return nil
    }

    /// Told after the frames were made or kept for the page's sections and scroll position: the key-view order follows.
    var onFramesChanged: (() -> Void)?

    /// The frame Tab reaches from the results: the first expanded, made frame on screen (`EntryPagePlan.firstKeyFrame`).
    var firstKeyView: EntryWebView? {
        let index = EntryPagePlan.firstKeyFrame(tops: sections.map { Double($0.holder.frame.minY) },
                                                heights: sections.map(\.frameHeight),
                                                collapsed: sections.map(\.collapsed),
                                                made: sections.map { $0.pane != nil },
                                                top: Double(scroll.contentView.bounds.minY))
        return index.flatMap { sections[$0].pane?.view }
    }

    @objc private func scrolled() {
        if let refusal = materialize() { onRefusal?(refusal) }
    }

    // MARK: - Heights

    /// A frame's document finished loading: measured, and watched for any later change of its height (a fold opened,
    /// an image arrived, the width or text size changed).
    func finished(_ pane: EntryPane) {
        guard let section = sections.first(where: { $0.pane === pane }) else { return }
        if firstPaint == nil { firstPaint = .now - asked }
        Task { @MainActor in
            let height = try? await pane.view.callAsyncJavaScript(Self.watchHeight, arguments: [:], in: nil,
                                                                  contentWorld: EntryPane.world) as? Double
            if let height { section.setHeight(height * zoom) }
            section.finished = true
            section.stand(.shown, saying: nil)
            landIfReady()
            if let refusal = materialize() { onRefusal?(refusal) }
        }
    }

    /// The document's height in CSS pixels, and a watcher posting it again whenever it changes: in the shell's world,
    /// whose handler the page cannot see or call. The body's contents to their last line, plus the body's and the
    /// root's bottom padding: never `scrollHeight`, which is never less than the frame and so could never shrink it.
    static let watchHeight = """
        const measure = () => {
            const body = document.body; if (!body) { return 0; }
            const range = document.createRange(); range.selectNodeContents(body);
            const b = getComputedStyle(body), h = getComputedStyle(document.documentElement);
            const text = range.getBoundingClientRect().bottom + window.scrollY + parseFloat(b.paddingBottom || "0")
                + parseFloat(b.marginBottom || "0") + parseFloat(h.paddingBottom || "0");
            // The root's own box: it holds a last paragraph's bottom margin, which collapses through the body and
            // which the text's rectangle leaves out (the lab saw a frame scroll by that margin).
            const root = document.documentElement.getBoundingClientRect().bottom + window.scrollY
                + parseFloat(h.marginBottom || "0");
            return Math.ceil(Math.max(text, root));
        };
        const reportScroll = () => window.webkit.messageHandlers.xdictPageScroll.postMessage(
            [window.scrollY, Math.max(0, document.documentElement.scrollHeight - window.innerHeight)]);
        if (!window.__xdictPageHeight && window.ResizeObserver) {
            let last = 0;
            window.__xdictPageHeight = new ResizeObserver(() => {
                const now = measure();
                if (now !== last) { last = now; window.webkit.messageHandlers.xdictPageHeight.postMessage(now); }
                reportScroll();
            });
            window.__xdictPageHeight.observe(document.documentElement);
            if (document.body) { window.__xdictPageHeight.observe(document.body); }
        }
        if (!window.__xdictScrollWatch) {
            window.__xdictScrollWatch = true;
            window.addEventListener("scroll", reportScroll, {passive: true});
            window.addEventListener("resize", reportScroll);
        }
        reportScroll();
        return measure();
        """

    static let scrollHandler = "xdictPageScroll"

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.world == EntryPane.world, let view = message.webView else { return }
            switch message.name {
            case Self.heightHandler:
                guard let height = (message.body as? NSNumber)?.doubleValue,
                      let section = sections.first(where: { $0.pane?.view === view }) else { return }
                section.setHeight(height * zoom)
            case Self.scrollHandler:
                // **The frame's own scroll position** (audit round 4, 2026-10-25): macOS's WKWebView has no public
                // `scrollView`, so the wheel's edge hand-off reads what the document reports about itself.
                guard let webView = view as? EntryWebView,
                      let numbers = message.body as? [NSNumber], numbers.count == 2 else { return }
                webView.innerScroll = (numbers[0].doubleValue, numbers[1].doubleValue)
            default:
                return
            }
        }
    }

    func setZoom(_ zoom: Double) {
        guard zoom != self.zoom else { return }
        let ratio = zoom / self.zoom
        self.zoom = zoom
        for section in sections {
            section.pane?.setZoom(zoom)
            section.setHeight(section.frameHeight * ratio)
            section.divider.setZoom(zoom)
        }
    }

    // MARK: - Scrolling

    /// How far down the page the reader is, in points.
    var offset: Double { Double(scroll.contentView.bounds.minY) }

    func scrollTo(_ y: Double) {
        let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Lands at the pending offset once every frame made so far has loaded (their heights decide where it is).
    private func landIfReady() {
        guard let target = pendingOffset, sections.allSatisfy({ $0.pane == nil || $0.finished }) else { return }
        pendingOffset = nil
        document.layoutSubtreeIfNeeded()
        scrollTo(target)
    }

    /// Scrolls the page so a point of a frame's document (CSS pixels from its top) is in the middle of the view.
    func reveal(_ section: EntryPageSection, documentY: Double) {
        document.layoutSubtreeIfNeeded()
        let y = Double(section.holder.frame.minY) + documentY * zoom
        scrollTo(y - Double(scroll.contentView.bounds.height) / 2)
    }

    // MARK: - Orientation (HIG audit UI24)

    /// Told when the page's dictionaries, the one being read, or whether its name is pinned changed.
    var onSourcesChanged: ((EntryPageSources) -> Void)?
    private var reportedSources: EntryPageSources?
    /// The current dictionary's name, pinned at the view's top while its divider is scrolled away.
    let sourceLabel = EntryPageSourceLabel()

    /// Each section's start in the page: its divider's top when it shows one, else its frame's (only the first
    /// section, expanded, goes without a divider, so a start is never a detached, hidden view's).
    private var starts: [Double] {
        sections.map { Double(($0.hasDivider ? $0.divider : $0.holder).frame.minY) }
    }

    /// The page's dictionaries in the reader's order, the one at the view's top, and whether its name is pinned.
    var sources: EntryPageSources {
        let starts = starts, top = offset
        let current = EntryPagePlan.current(starts: starts, top: top)
        return EntryPageSources(
            sources: sections.map { EntryPageSource(id: $0.id, name: $0.name) },
            current: current.map { sections[$0].id },
            pinned: current.map { EntryPagePlan.pinsSource(current: $0, starts: starts, top: top, style: style) } ?? false)
    }

    private func reportSources() {
        document.layoutSubtreeIfNeeded()
        let next = sources
        guard next != reportedSources else { return }
        reportedSources = next
        sourceLabel.show(next.pinned ? next.currentName : nil)
        onSourcesChanged?(next)
    }

    /// **Jumps to a dictionary** (UI24): its divider (the page's top, for the first) at the view's top; a collapsed
    /// dictionary stays collapsed, its divider showing where it is.
    func jump(to id: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        pendingOffset = nil
        document.layoutSubtreeIfNeeded()
        scrollTo(starts[index])
        if let refusal = materialize() { onRefusal?(refusal) }
    }

    // MARK: - Evidence (HIG audit UI11)

    /// The name each section's frame answers to: its dictionary's handle and edition, and its record.
    private var frameNames: [EntryFrameName] {
        sections.map {
            EntryFrameName(handle: $0.item.content.binding.handle, edition: $0.item.content.binding.edition,
                           reference: $0.item.reference)
        }
    }

    /// **An answer's evidence, shown in the one frame its frozen target names** (UI11): never the page at large, so two
    /// dictionaries with similar wording cannot be confused. That frame is opened for the reveal if collapsed (the
    /// reader's kept collapse for the dictionary is left as it is), made and loaded, and searched alone; its match is
    /// brought to the middle of the view. False when no single frame carries the name, or its text has no visible match.
    func revealEvidence(_ text: String, in name: EntryFrameName) async -> Bool {
        guard let index = EntryPagePlan.frame(named: name, among: frameNames) else { return false }
        let section = sections[index]
        if section.collapsed {
            section.collapsed = false
            section.hasDivider = EntryPagePlan.hasDivider(at: index, collapsed: false, style: style)
            onContentHeightChanged?()
        }
        pendingOffset = nil
        document.layoutSubtreeIfNeeded()
        scrollTo(Double(section.holder.frame.minY))
        let mine = pageGeneration
        if let refusal = materialize(including: index) {
            onRefusal?(refusal)
            return false
        }
        // **A frame that timed out is not a frame to search** (audit round 4, 2026-10-25): the reveal would report a
        // missing word from a document that had not finished loading.
        guard case .loaded = await loaded() else { return false }
        // **The page may have been shown again while it loaded** (audit round 4, 2026-10-25): the reveal's own generation
        // and the section must both still stand before a frame is searched or scrolled.
        guard mine == pageGeneration, sections.contains(where: { $0 === section }), let pane = section.pane else {
            return false
        }
        await clearFind()
        guard mine == pageGeneration, sections.contains(where: { $0 === section }) else { return false }
        guard let result = await pane.find(text), result.visible > 0 else {
            // **A page shown again owns its own find** (audit round 4, 2026-10-25): the old reveal's clear would take it.
            if mine == pageGeneration { await pane.clearFind() }
            return false
        }
        // **A match that cannot be placed is not a reveal** (audit round 4, 2026-10-25): a failed script call or a null
        // position used to be reported as a shown match.
        guard let y = try? await pane.view.callAsyncJavaScript(Self.currentMatchTop, arguments: [:], in: nil,
                                                               contentWorld: EntryPane.world) as? Double else {
            if mine == pageGeneration { await pane.clearFind() }
            return false
        }
        guard mine == pageGeneration, sections.contains(where: { $0 === section }) else { return false }
        reveal(section, documentY: y)
        return true
    }

    // MARK: - Find, across frames (R3, P30)

    /// Which find may still publish; a clear or a newer find advances it (audit round 3).
    private var findSerial = 0

    private func clearFindState() {
        findQuery = ""
        findCounts = []
        findCurrent = nil
        findHidden = 0
    }

    /// Finds `query` in every frame (each made first), the first match current; collapsed dictionaries' matches are
    /// counted as hidden, as folded ones are. **A find a newer one or a clear overtook publishes nothing** (audit round 3,
    /// 2026-10-25): the loop checks its serial after every suspension, not only at the end.
    func find(_ query: String) async -> EntryFindResult? {
        if let refusal = materialize(all: true) {
            onRefusal?(refusal)
            return nil
        }
        guard case .loaded = await loaded() else { return nil }
        findSerial += 1
        let mine = findSerial
        guard !Task.isCancelled, mine == findSerial else { return nil }
        findQuery = query
        var counts: [Int] = [], hidden = 0
        for section in sections {
            guard !Task.isCancelled, mine == findSerial else { return nil }
            guard let pane = section.pane, let result = await pane.find(query) else {
                counts.append(0)
                continue
            }
            guard !Task.isCancelled, mine == findSerial else { return nil }
            hidden += result.hidden + (section.collapsed ? result.visible : 0)
            counts.append(section.collapsed ? 0 : result.visible)
            await clearCurrent(pane)
        }
        guard !Task.isCancelled, mine == findSerial else { return nil }
        findCounts = counts
        findCurrent = nil
        findHidden = hidden
        return await move(to: EntryPagePlan.step(from: nil, counts: counts, forward: true))
    }

    func findStep(forward: Bool) async -> EntryFindResult? {
        guard !findQuery.isEmpty else { return nil }
        return await move(to: EntryPagePlan.step(from: findCurrent, counts: findCounts, forward: forward),
                          forward: forward)
    }

    func clearFind() async {
        findSerial += 1
        clearFindState()
        // **A page shown again is not cleared by the old one's clear** (audit round 4, 2026-10-25): a reused pane may
        // already carry the new page's find.
        let mine = pageGeneration
        for pane in panes {
            guard mine == pageGeneration else { return }
            await pane.clearFind()
        }
    }

    private func move(to next: (section: Int, match: Int)?, forward: Bool = true) async -> EntryFindResult? {
        let mine = findSerial
        let hidden = findHidden
        let total = findCounts.reduce(0, +)
        // **Even the no-match branch obeys the serial** (verification round 3, 2026-10-25): a clear before this move began
        // must not be overwritten by its nil.
        guard !Task.isCancelled, mine == findSerial else { return nil }
        guard let next, let pane = sections[next.section].pane else {
            findCurrent = nil
            return EntryFindResult(visible: total, hidden: hidden, current: 0)
        }
        if let current = findCurrent, current.section == next.section {
            _ = await pane.findStep(forward: forward)
        } else {
            if let current = findCurrent, let old = sections[current.section].pane { await clearCurrent(old) }
            guard !Task.isCancelled, mine == findSerial else { return nil }
            _ = await pane.find(findQuery)
            for _ in 0..<next.match {
                guard !Task.isCancelled, mine == findSerial else { return nil }
                _ = await pane.findStep(forward: true)
            }
        }
        // **A clear or a newer find owns the page by now** (audit rounds 3 and 4): this move neither publishes a position
        // nor scrolls a document the reader has left.
        guard !Task.isCancelled, mine == findSerial else { return nil }
        findCurrent = next
        if let y = try? await pane.view.callAsyncJavaScript(Self.currentMatchTop, arguments: [:], in: nil,
                                                             contentWorld: EntryPane.world) as? Double {
            guard !Task.isCancelled, mine == findSerial else { return nil }
            reveal(sections[next.section], documentY: y)
        }
        guard !Task.isCancelled, mine == findSerial else { return nil }
        return EntryFindResult(visible: total, hidden: hidden, current: EntryPagePlan.position(next, counts: findCounts))
    }

    /// The current match's top in its document, in CSS pixels: read off the highlight find.js paints.
    static let currentMatchTop = """
        const h = window.CSS && CSS.highlights && CSS.highlights.get("xdict-find-current");
        if (!h) { return null; }
        for (const r of h) { const b = r.getBoundingClientRect(); return b.top + window.scrollY + b.height / 2; }
        return null;
        """

    private func clearCurrent(_ pane: EntryPane) async {
        _ = try? await pane.view.callAsyncJavaScript(
            "if (window.CSS && CSS.highlights) { CSS.highlights.delete('xdict-find-current'); } return 0;",
            arguments: [:], in: nil, contentWorld: EntryPane.world)
    }

    /// How a wait for the page's frames ended.
    enum LoadOutcome {
        case loaded
        case timedOut
        case cancelled
    }

    /// Returns once every frame made has loaded its document, a timeout after two seconds, or at once on cancellation.
    private func loaded() async -> LoadOutcome {
        // **A cancelled caller is answered at once, even with every frame finished** (audit round 4, 2026-10-25): the
        // loop's own check never ran in that case, and a cancelled print or reveal went on to act.
        if Task.isCancelled { return .cancelled }
        let deadline = ContinuousClock.now + .seconds(2)
        while sections.contains(where: { $0.pane != nil && !$0.finished }) {
            if Task.isCancelled { return .cancelled }
            guard ContinuousClock.now < deadline else { return .timedOut }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return .cancelled
            }
        }
        return .loaded
    }

    // MARK: - Print (P44)

    /// The whole page for print: every frame made and loaded, each expanded one drawn (a PDF of its web view, as
    /// shown) under its dictionary's name; `nil` when a frame could not be made.
    func printView() async -> NSView? {
        if let refusal = materialize(all: true) {
            onRefusal?(refusal)
            return nil
        }
        if case .loaded = await loaded() {} else { return nil }
        let drawn = await withLightFrames {
            await printDrawings()
        }
        guard let (frames, collapsed, images) = drawn else { return nil }
        let plan = EntryPrintPlan.layout(frames, collapsed: collapsed)
        guard !plan.isEmpty, plan.count == images.count else {
            EntryLog.logger.error("print: \(plan.count) sections planned for \(images.count) drawings")
            return nil
        }
        let width = max(scroll.contentView.bounds.width, 1)
        return EntryPagePrintView(width: width, sections: Array(zip(plan, images)))
    }

    /// On paper, as Apple's prints: a frame shown dark is drawn light for print, then shown as it was. Nil when the
    /// light frames did not load in time: restoring the scheme reloads them, so a capture taken after the restore would
    /// draw the dark twin of what was asked for (audit round 4, 2026-10-25).
    private func withLightFrames<T>(_ body: () async -> T?) async -> T? {
        let dark = sections.compactMap(\.pane).filter { $0.scheme == .dark }
        guard !dark.isEmpty else { return await body() }
        for section in sections where section.pane.map({ pane in dark.contains { $0 === pane } }) == true {
            section.finished = false
        }
        for pane in dark { pane.setScheme(.light) }
        guard case .loaded = await loaded() else {
            for pane in dark { pane.setScheme(.dark) }
            return nil
        }
        let result = await body()
        for pane in dark { pane.setScheme(.dark) }
        return result
    }

    /// Each section's drawing for print: its height and line breaks, and the expanded frames' PDFs. Nil when a frame
    /// cannot be drawn or measured.
    private func printDrawings() async -> ([(String, Double, [Double])], [Bool], [NSImage])? {
        var frames: [(String, Double, [Double])] = []
        var collapsed: [Bool] = []
        var images: [NSImage] = []
        for section in sections {
            guard !section.collapsed, let pane = section.pane else {
                frames.append((section.name, 0, []))
                collapsed.append(true)
                continue
            }
            do {
                let data = try await pane.view.pdf(configuration: WKPDFConfiguration())
                guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                let lines = (try? await pane.view.callAsyncJavaScript(EntryPrintPlan.linesScript, arguments: [:],
                                                                       in: nil, contentWorld: EntryPane.world))
                    as? [[NSNumber]]
                let boxes = (lines ?? []).compactMap { box in
                    box.count == 2 ? (box[0].doubleValue * zoom, box[1].doubleValue * zoom) : nil
                }
                frames.append((section.name, section.frameHeight, EntryPrintPlan.breaks(lines: boxes)))
                collapsed.append(false)
                images.append(image)
            } catch {
                EntryLog.logger.error("print: a frame could not be drawn: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return (frames, collapsed, images)
    }

    // MARK: - Which frame

    /// The frame the reader is in: the one holding the keyboard, else the one at the top of the view.
    func frameInFocus(window: NSWindow?) -> EntryPane? {
        if let responder = window?.firstResponder as? NSView,
           let pane = panes.first(where: { responder === $0.view || responder.isDescendant(of: $0.view) }) {
            return pane
        }
        let top = scroll.contentView.bounds.minY
        return sections.first { !$0.collapsed && $0.pane != nil && $0.holder.frame.maxY > top }?.pane ?? panes.first
    }
}
