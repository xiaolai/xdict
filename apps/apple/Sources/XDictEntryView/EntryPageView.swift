import AppKit
import WebKit
import os
import XDictTokens

/// **Apple's divider between two dictionaries** (parity P15, measured on Dictionary.app): a disclosure triangle at the
/// leading edge, a 1 pt grey rule across the pane, and the dictionary's name centred in it in the secondary label colour,
/// at the system's `large` size. A click anywhere on it, or VoiceOver's press, collapses or expands that dictionary.
/// Its name, band and triangle follow the one text size, as Apple's do (P15, P29).
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
        return Metrics(font: Tokens.PageDivider.font * scale, height: height * scale, triangle: Tokens.PageDivider.triangle * scale)
    }
    /// The rule: #929292 measured on Apple's page in light; its dark twin keeps the same contrast with #1e1e1e.
    static var ruleColour: NSColor { Tokens.Colour.entryRule.nsColor }

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
            label.font = .systemFont(ofSize: metrics.font)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            let height = heightAnchor.constraint(equalToConstant: metrics.height)
            heightConstraint = height
            NSLayoutConstraint.activate([
                height,
                label.centerXAnchor.constraint(equalTo: centerXAnchor, constant: (Self.ruleStart - Self.trailing) / 2),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -(Self.ruleStart + Self.trailing + 48)),
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
        label.font = .systemFont(ofSize: next.font)
        heightConstraint?.constant = next.height
        needsDisplay = true
    }

    /// Apple's geometry, in points from the pane's leading edge: the triangle centred at 29, the rule from 45 to 16
    /// short of the trailing edge, a 12 pt gap each side of the name.
    static let triangleCentre: CGFloat = Tokens.PageDivider.triangleCentre
    static let ruleStart: CGFloat = Tokens.PageDivider.ruleStart
    static let trailing: CGFloat = Tokens.PageDivider.trailing
    static let gap: CGFloat = Tokens.PageDivider.gap

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let mid = (bounds.height / 2).rounded(.down) + 0.5
        if style == .popover {
            // The title row's hairline: the separator colour, from just after the name to the trailing inset.
            let start = label.frame.maxX + Popover.gap, end = bounds.maxX - Popover.trailing
            guard end > start else { return }
            NSColor.separatorColor.setStroke()
            let rule = NSBezierPath()
            rule.lineWidth = 1
            rule.move(to: NSPoint(x: start, y: mid))
            rule.line(to: NSPoint(x: end, y: mid))
            rule.stroke()
            return
        }
        let colour = Self.ruleColour
        colour.setStroke()
        let text = label.frame.insetBy(dx: -Self.gap, dy: 0)
        let rule = NSBezierPath()
        rule.lineWidth = 1
        rule.move(to: NSPoint(x: Self.ruleStart, y: mid))
        rule.line(to: NSPoint(x: max(Self.ruleStart, text.minX), y: mid))
        rule.move(to: NSPoint(x: min(bounds.maxX - Self.trailing, text.maxX), y: mid))
        rule.line(to: NSPoint(x: bounds.maxX - Self.trailing, y: mid))
        rule.stroke()
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

/// **One dictionary's part of the page**: its divider, and its frame — a pane of its own (`EntryPane`), made when it is
/// first needed, sized to its document so it never scrolls inside.
@MainActor
final class EntryPageSection {
    let item: EntryPageItem
    let divider: EntryPageDivider
    /// What the frame's web view sits in, at the document's height.
    let holder = NSView()
    private let height: NSLayoutConstraint
    private(set) var pane: EntryPane?
    var collapsed: Bool { didSet { apply() } }
    var hasDivider = true { didSet { apply() } }
    /// The frame's document has loaded at least once, and the frame has taken its height.
    var finished = false
    /// Told when the frame's height changed: the page's height is news to whoever sizes to it (the popover).
    var onHeightChange: (() -> Void)?

    var id: UUID { item.id }
    var name: String { item.name }

    init(item: EntryPageItem, collapsed: Bool, zoom: Double = 1, style: EntryPageStyle = .window) {
        self.item = item
        self.collapsed = collapsed
        divider = EntryPageDivider(name: item.name, zoom: zoom, style: style)
        holder.translatesAutoresizingMaskIntoConstraints = false
        height = holder.heightAnchor.constraint(equalToConstant: CGFloat(EntryPagePlan.estimatedHeight))
        height.priority = .required
        height.isActive = true
        apply()
    }

    /// The frame's height in points, as laid out now.
    var frameHeight: Double { Double(height.constant) }

    func setHeight(_ points: Double) {
        let clamped = CGFloat(min(max(points, 1), EntryPage.maximumFrameHeight))
        guard abs(height.constant - clamped) >= 0.5 else { return }
        height.constant = clamped
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
        holder.addSubview(view)
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
        let old = Dictionary(sections.map { ($0.item.identity, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: Set<ObjectIdentifier> = []
        var next: [EntryPageSection] = []
        for item in items {
            if let section = old[item.identity], !kept.contains(ObjectIdentifier(section)) {
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
            clearFindState()
        }
        sections = next
        for (index, section) in next.enumerated() {
            section.hasDivider = EntryPagePlan.hasDivider(at: index, collapsed: section.collapsed, style: style)
            section.divider.onToggle = { [weak self, weak section] in
                guard let self, let section else { return }
                self.toggle(section)
            }
            section.onHeightChange = { [weak self] in self?.onContentHeightChanged?() }
        }
        let views = next.flatMap { [$0.divider as NSView, $0.holder] }
        if stack.arrangedSubviews != views {
            for view in stack.arrangedSubviews where !views.contains(view) { stack.removeArrangedSubview(view) }
            for (index, view) in views.enumerated() {
                stack.insertArrangedSubview(view, at: index)
            }
        }
        if let offset { pendingOffset = offset } else if kept.isEmpty { scrollTo(0) }
        onContentHeightChanged?()
        return materialize()
    }

    func close() {
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
            section.hasDivider = EntryPagePlan.hasDivider(at: index, collapsed: section.collapsed, style: style)
        }
        onContentHeightChanged?()
        if let refusal = materialize() { onRefusal?(refusal) }
    }

    /// Makes the frames the viewport wants (or every frame, for find); the first refusal stops it.
    @discardableResult
    func materialize(all: Bool = false) -> EntryRefusal? {
        document.layoutSubtreeIfNeeded()
        let indices: [Int]
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
        for index in indices where sections[index].pane == nil {
            let section = sections[index]
            switch make(section) {
            case .failure(let why): return why
            case .success(let pane):
                section.attach(pane)
                pane.setZoom(zoom)
                pane.view.configuration.userContentController.add(self, contentWorld: EntryPane.world,
                                                                  name: Self.heightHandler)
                Task { _ = await pane.show(section.item.reference) }
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
        if (!window.__xdictPageHeight && window.ResizeObserver) {
            let last = 0;
            window.__xdictPageHeight = new ResizeObserver(() => {
                const now = measure();
                if (now !== last) { last = now; window.webkit.messageHandlers.xdictPageHeight.postMessage(now); }
            });
            window.__xdictPageHeight.observe(document.documentElement);
            if (document.body) { window.__xdictPageHeight.observe(document.body); }
        }
        return measure();
        """

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.world == EntryPane.world, let height = (message.body as? NSNumber)?.doubleValue,
                  let view = message.webView,
                  let section = sections.first(where: { $0.pane?.view === view }) else { return }
            section.setHeight(height * zoom)
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

    // MARK: - Find, across frames (R3, P30)

    private func clearFindState() {
        findQuery = ""
        findCounts = []
        findCurrent = nil
        findHidden = 0
    }

    /// Finds `query` in every frame (each made first), the first match current; collapsed dictionaries' matches are
    /// counted as hidden, as folded ones are.
    func find(_ query: String) async -> EntryFindResult? {
        if let refusal = materialize(all: true) {
            onRefusal?(refusal)
            return nil
        }
        await loaded()
        findQuery = query
        var counts: [Int] = [], hidden = 0
        for section in sections {
            guard let pane = section.pane, let result = await pane.find(query) else {
                counts.append(0)
                continue
            }
            hidden += result.hidden + (section.collapsed ? result.visible : 0)
            counts.append(section.collapsed ? 0 : result.visible)
            await clearCurrent(pane)
        }
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
        clearFindState()
        for pane in panes { await pane.clearFind() }
    }

    private func move(to next: (section: Int, match: Int)?, forward: Bool = true) async -> EntryFindResult? {
        let hidden = findHidden
        let total = findCounts.reduce(0, +)
        guard let next, let pane = sections[next.section].pane else {
            findCurrent = nil
            return EntryFindResult(visible: total, hidden: hidden, current: 0)
        }
        if let current = findCurrent, current.section == next.section {
            _ = await pane.findStep(forward: forward)
        } else {
            if let current = findCurrent, let old = sections[current.section].pane { await clearCurrent(old) }
            _ = await pane.find(findQuery)
            for _ in 0..<next.match { _ = await pane.findStep(forward: true) }
        }
        findCurrent = next
        if let y = try? await pane.view.callAsyncJavaScript(Self.currentMatchTop, arguments: [:], in: nil,
                                                             contentWorld: EntryPane.world) as? Double {
            reveal(sections[next.section], documentY: y)
        }
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

    /// Returns once every frame made has loaded its document, or after two seconds.
    private func loaded() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while sections.contains(where: { $0.pane != nil && !$0.finished }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Print (P44)

    /// The whole page for print: every frame made and loaded, each expanded one drawn (a PDF of its web view, as
    /// shown) under its dictionary's name; `nil` when a frame could not be made.
    func printView() async -> NSView? {
        if let refusal = materialize(all: true) {
            onRefusal?(refusal)
            return nil
        }
        await loaded()
        // On paper, as Apple's prints: a frame shown dark is drawn light for print, then shown as it was.
        let dark = sections.compactMap(\.pane).filter { $0.scheme == .dark }
        if !dark.isEmpty {
            for section in sections where section.pane.map({ pane in dark.contains { $0 === pane } }) == true { section.finished = false }
            for pane in dark { pane.setScheme(.light) }
            await loaded()
        }
        defer {
            for pane in dark { pane.setScheme(.dark) }
        }
        var frames: [(String, Double, [Double])] = []
        var collapsed: [Bool] = []
        var images: [NSImage] = []
        for section in sections {
            guard !section.collapsed, let pane = section.pane else {
                frames.append((section.name, 0, []))
                collapsed.append(true)
                continue
            }
            let image: NSImage
            do {
                let data = try await pane.view.pdf(configuration: WKPDFConfiguration())
                guard let drawn = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                image = drawn
            } catch {
                EntryLog.logger.error("print: a frame could not be drawn: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            let lines = (try? await pane.view.callAsyncJavaScript(EntryPrintPlan.linesScript, arguments: [:], in: nil,
                                                                   contentWorld: EntryPane.world)) as? [[NSNumber]]
            let boxes = (lines ?? []).compactMap { box in
                box.count == 2 ? (box[0].doubleValue * zoom, box[1].doubleValue * zoom) : nil
            }
            frames.append((section.name, section.frameHeight, EntryPrintPlan.breaks(lines: boxes)))
            collapsed.append(false)
            images.append(image)
        }
        let plan = EntryPrintPlan.layout(frames, collapsed: collapsed)
        guard !plan.isEmpty, plan.count == images.count else {
            EntryLog.logger.error("print: \(plan.count) sections planned for \(images.count) drawings")
            return nil
        }
        let width = max(scroll.contentView.bounds.width, 1)
        return EntryPagePrintView(width: width, sections: Array(zip(plan, images)))
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
