import AppKit
import XDictBase
import XDictCapture
import os

/// Where hover's events come from — **the seam that lets the watcher be driven by a test.**
@MainActor
protocol HoverEventSource: AnyObject {
    /// Starts delivering events. **False if any monitor could not be installed**, and then none is left installed: one
    /// surviving monitor would make hover report itself on with a gesture missing.
    func start(_ handler: @escaping @MainActor (HoverEvent) -> Void) -> Bool
    func stop()
}

/// **Watches the pointer and hands over the word under it** once the reader has rested with the modifier held, or tapped
/// it twice (ported from XiaolaiDict's `HoverWatcher`, plan-capture WI-3).
///
/// **A shell around `HoverSession`**, which holds every decision about a request's lifecycle: when to ask, whether a
/// result still stands, what is owed when a read ends. This file turns AppKit events into the session's inputs and the
/// session's effects into timers, reads and deliveries, and decides nothing itself.
///
/// **What it hands over goes through the app's one `CaptureRequests`** (ADR-0014 decision 4): a request is numbered when
/// its read is asked, before the read runs, in the same order as the shortcut's, the Service's and the menu's; its word
/// claims presentation only when it is presented (`present`), and every request it numbered ends exactly once — delivered
/// and then acknowledged by the consumer, or cancelled here when its read is dropped or finds nothing.
@MainActor
public final class HoverWatcher {
    /// Cancels a scheduled piece of work.
    typealias Cancel = @MainActor () -> Void
    /// Runs `work` after `delay`, on the main actor, and returns how to cancel it.
    typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> Cancel

    private let log = Logger(subsystem: XDictIdentity.app, category: "hover")
    /// Not private, so a test can ask the reader what it decided.
    let reader: any HoverReading
    private let policy: @MainActor () -> HoverPolicy
    private let requests: CaptureRequests
    private let primaryHeight: @MainActor () -> CGFloat?
    private let events: any HoverEventSource
    private let pointer: @MainActor () -> (UpPoint, Set<HoverModifier>)
    private let schedule: Schedule
    private let now: @MainActor () -> ContinuousClock.Instant

    private var session: HoverSession
    private var watching = false
    private var cancelSettle: Cancel?
    private var readTask: Task<Void, Never>?
    /// What a read found, kept until the session says whether to deliver it.
    private var found: [Int: Found] = [:]
    /// A read's answer awaiting the session's word: a word to present, or a notice to tell (plan-capture WI-4).
    private enum Found {
        case word(PointerWordReader.Hit, request: CaptureRequest, key: String)
        case recognised(Recognition, request: CaptureRequest, key: String, context: PendingContext?)
        case notice(CaptureNotice, request: CaptureRequest)

        var request: CaptureRequest {
            switch self {
            case .word(_, let request, _), .recognised(_, let request, _, _), .notice(_, let request): request
            }
        }

        /// Nobody will show it: a pending context it carries is cancelled.
        func discard() {
            if case .recognised(_, _, _, let context) = self { context?.cancel() }
        }
    }
    /// Each request's number and when it was asked — **by origin**, so a tap served after the read it waited for keeps
    /// the number and the time of the gesture that asked.
    private var origins: [Int: (request: CaptureRequest, instant: ContinuousClock.Instant)] = [:]
    /// The key of each word delivered and not yet acknowledged, by request number: forgotten unless it was shown.
    private var delivered: [Int: String] = [:]
    /// How many delivered words are remembered awaiting their acknowledgement; more than one or two are never live.
    private static let rememberedDeliveries = 16
    /// Inputs that arrived while effects were being carried out, handled in arrival order.
    private var queued: [HoverSession.Input] = []
    private var handling = false

    /// Where a word goes: the consumer. Weak: the app owns the watcher.
    public weak var sink: (any CaptureSink)?
    /// Whether the lane is answering — forwarded from the reader for the consumer's notice.
    public var onCaptureHealth: (@MainActor (CaptureHealth) -> Void)?
    /// What the consumer should tell the reader (Screen Recording needed), for a hover that still stands. Kinds only.
    public var onNotice: (@MainActor (CaptureNotice) -> Void)?

    init(
        policy: @escaping @MainActor () -> HoverPolicy, requests: CaptureRequests, restTolerance: CGFloat,
        primaryHeight: @escaping @MainActor () -> CGFloat?, events: any HoverEventSource,
        pointer: @escaping @MainActor () -> (UpPoint, Set<HoverModifier>), schedule: @escaping Schedule,
        now: @escaping @MainActor () -> ContinuousClock.Instant, reader: any HoverReading
    ) {
        self.policy = policy
        self.requests = requests
        self.primaryHeight = primaryHeight
        self.events = events
        self.pointer = pointer
        self.schedule = schedule
        self.now = now
        self.reader = reader
        session = HoverSession(now: now(), restTolerance: restTolerance)
        reader.onCaptureHealth = { [weak self] health in self?.onCaptureHealth?(health) }
        // **A read refused for the busy capture is asked again when it ends**, not when the pointer next twitches.
        reader.onCaptureReleased = { [weak self] in self?.captureReleased() }
        // **Every ending is the consumer's word on a word delivered**: one not shown is forgotten, so resting on it asks
        // again. Told on whatever thread ended it; the watcher's state is the main actor's.
        requests.onEnd { [weak self] ack in
            Task { @MainActor in self?.ended(ack) }
        }
    }

    /// **The watcher the app runs**: the system's events, pointer, screens, timer and clock, and a reader over `source`
    /// on the same policy and pause, starting its pending contexts in `contexts` — the consumer's session's book, so a
    /// presented term's handle is found there. `restTolerance` comes from the composition layer's tokens (decision 11).
    public convenience init(
        policy: @escaping @MainActor () -> HoverPolicy, pause: @escaping @MainActor () -> HoverPause,
        requests: CaptureRequests, source: any PointerWordSource, contexts: PendingContexts, restTolerance: CGFloat
    ) {
        self.init(
            policy: policy, requests: requests, restTolerance: restTolerance,
            primaryHeight: { HoverWatcher.primaryHeight(among: NSScreen.screens.map { UpRect($0.frame) }) },
            events: SystemHoverEvents(), pointer: HoverWatcher.systemPointer, schedule: HoverWatcher.onMainQueue,
            now: { .now }, reader: HoverReader(policy: policy, pause: pause, source: source, contexts: contexts))
    }

    public var isWatching: Bool { watching }

    public func start() {
        guard !watching else { return }
        guard events.start({ [weak self] event in self?.handle(event) }) else {
            log.error("hover: could not watch the pointer and keys")
            return
        }
        watching = true
        feed(.start)
    }

    public func stop() {
        events.stop()
        watching = false
        // A key let go while stopped is never seen, so the suppression it would have lifted is lifted here.
        reader.endHover()
        feed(.stop)
        // A tap reserved and never asked will not be: its request ends now. The read in flight ends its own when it does.
        for origin in origins.keys where origin != session.inFlight?.origin { finishOrigin(origin) }
    }

    private func handle(_ event: HoverEvent) {
        switch event {
        case .pointerMoved:
            let (at, held) = pointer()
            feed(.pointer(at, held: held))
        case .modifiers(let held, let instant, let location):
            // **From the event, not from current state**: global monitors deliver asynchronously.
            let at = location ?? pointer().0
            // **Letting go of the hold key ends the hover, and with it the suppression.**
            if !held.contains(policy().modifier) { reader.endHover() }
            feed(.modifiers(held, at: instant, pointer: at))
            feed(.pointer(at, held: held))
        case .otherInput:
            feed(.otherInput)
        }
    }

    private func feed(_ input: HoverSession.Input) {
        queued.append(input)
        guard !handling else { return }
        handling = true
        defer { handling = false }
        while !queued.isEmpty {
            let next = queued.removeFirst()
            let policy = policy()
            let settings = HoverSession.Settings(gesture: policy.gesture, modifier: policy.modifier)
            for effect in session.handle(next, settings: settings, now: now()) { perform(effect) }
        }
    }

    private func perform(_ effect: HoverEffect) {
        switch effect {
        case .scheduleSettle:
            cancelSettle?()
            cancelSettle = schedule(.milliseconds(policy().settleMilliseconds)) { [weak self] in
                guard let self else { return }
                self.cancelSettle = nil
                let (at, held) = self.pointer()
                self.feed(.settled(at, held: held))
            }
        case .cancelSettle:
            cancelSettle?()
            cancelSettle = nil
        case .ask(let intent):
            ask(intent)
        case .reserve(let intent):
            _ = number(for: intent)
        case .cancelRead:
            readTask?.cancel()
        case .deliver(let intent):
            deliver(intent)
        case .drop(let intent, let why):
            found.removeValue(forKey: intent.serial)?.discard()
            finishOrigin(intent.origin)
            log.debug("hover dropped: \(why.rawValue, privacy: .public)")
        }
    }

    private func ask(_ intent: HoverIntent) {
        guard let height = primaryHeight() else {
            log.error("hover: no display to measure from")
            queued.append(.readEnded(serial: intent.serial, .nothing, pointer: intent.point, held: intent.held))
            return
        }
        // **The number is taken now, synchronously**, so its place in line is this moment.
        let request = number(for: intent)
        readTask = Task { [weak self, reader] in
            // The y-down point the reader works in, made by the one explicit conversion on this line.
            let outcome = await reader.read(
                at: intent.point.flipped(aboutPrimaryHeight: height).cg, modifiersHeld: intent.held,
                tappedTwice: intent.tapped, pointerStillFor: intent.stillFor, begin: { request })
            self?.finish(intent, outcome)
        }
    }

    /// The request for `intent`'s origin — numbered the first time it is asked or reserved, the same every time after.
    private func number(for intent: HoverIntent) -> CaptureRequest {
        if let known = origins[intent.origin] { return known.request }
        let request = requests.begin(.pointerGesture)
        origins[intent.origin] = (request, now())
        return request
    }

    /// An origin whose request will not be presented: it ends here, cancelled, exactly once.
    private func finishOrigin(_ origin: Int) {
        guard let asked = origins.removeValue(forKey: origin) else { return }
        requests.cancel(asked.request)
    }

    private func finish(_ intent: HoverIntent, _ outcome: HoverReader.Outcome) {
        if session.inFlight?.serial == intent.serial { readTask = nil }
        let end: HoverSession.ReadEnd
        switch outcome {
        case .word(let hit, let request, let key):
            found[intent.serial] = .word(hit, request: request, key: key)
            end = .word
        case .recognised(let read, let request, let key, let context):
            found[intent.serial] = .recognised(read, request: request, key: key, context: context)
            end = .word
        case .needsScreenRecording(let request):
            // **Told only for a hover that still stands**: the session decides, as it does for a word.
            found[intent.serial] = .notice(.screenRecordingNeeded, request: request)
            end = .word
        case .quiet(.captureInFlight):
            end = .captureBusy
        case .quiet, .nothing:
            end = .nothing
        }
        let (at, held) = pointer()
        feed(.readEnded(serial: intent.serial, end, pointer: at, held: held))
        // A read that found nothing to present ends its request, unless a tap waiting under the same origin is still owed.
        if end == .nothing, session.inFlight?.origin != intent.origin { finishOrigin(intent.origin) }
    }

    private func deliver(_ intent: HoverIntent) {
        guard let word = found.removeValue(forKey: intent.serial) else { return }
        let asked = origins.removeValue(forKey: intent.origin) ?? (word.request, now())
        let pointer = primaryHeight().map { PointerSample(point: intent.point.flipped(aboutPrimaryHeight: $0), at: asked.instant) }
        let term: CapturedTerm
        let key: String
        do {
            switch word {
            case .word(let hit, _, let read):
                term = try hit.capturedTerm(pointer: pointer)
                key = read
            case .recognised(let recognition, _, let read, let context):
                // **The rest of the sentence travels as its handle**; the session finds the reading by it.
                term = try recognition.capturedTerm(pointer: pointer, context: context.map { .pending($0.handle) })
                key = read
            case .notice(let notice, let request):
                // Nothing is presented for a notice: its request ends, and the consumer tells the reader.
                requests.cancel(request)
                onNotice?(notice)
                return
            }
        } catch {
            // A read the validating constructor refuses is not a word: its request ends, and nothing is remembered.
            word.discard()
            requests.cancel(word.request)
            log.notice("hover: a read was refused as a captured term (\(String(describing: error), privacy: .public))")
            return
        }
        guard requests.present(term, for: word.request, to: sink) == .accepted else {
            word.discard()
            log.debug("hover dropped: a later request has the presentation")
            return
        }
        // Remembered on delivery, so a rest on the same word does not ask again while it comes up — and **forgotten if
        // its presentation never draws**, by the consumer's acknowledgement (`ended`).
        reader.remember(key)
        delivered[word.request.number] = key
        while delivered.count > Self.rememberedDeliveries, let oldest = delivered.keys.min() { delivered[oldest] = nil }
    }

    /// The one capture ended: a hover refused for it is asked again, at the pointer as it is now.
    private func captureReleased() {
        let (at, held) = pointer()
        feed(.captureReleased(at, held: held))
    }

    /// A request ended. A word delivered under it and not shown is forgotten.
    private func ended(_ ack: CaptureAcknowledgement) {
        guard let key = delivered.removeValue(forKey: ack.request), ack.outcome != .shown else { return }
        reader.forget(key)
    }

    // MARK: - The system's own sources

    /// The pointer and the hover modifiers held, read now.
    static func systemPointer() -> (UpPoint, Set<HoverModifier>) {
        (UpPoint(NSEvent.mouseLocation), modifiers(of: NSEvent.modifierFlags))
    }

    static func onMainQueue(_ delay: Duration, _ work: @escaping @MainActor () -> Void) -> Cancel {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        let parts = delay.components
        let nanoseconds = Int(parts.seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000)
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds), execute: item)
        return { item.cancel() }
    }

    // MARK: - What only the watcher decides

    /// The hover modifiers among whatever is held. Caps lock, function and the rest are not hover modifiers.
    nonisolated static func modifiers(of flags: NSEvent.ModifierFlags) -> Set<HoverModifier> {
        var held: Set<HoverModifier> = []
        if flags.contains(.option) { held.insert(.option) }
        if flags.contains(.control) { held.insert(.control) }
        if flags.contains(.command) { held.insert(.command) }
        if flags.contains(.shift) { held.insert(.shift) }
        return held
    }

    /// The height CGEvent measures down from: the display holding the global origin, found by **containing** it (an
    /// origin does not read the same in both spaces). Nil rather than zero with no display at all: a flip about zero
    /// would put every lookup at the top of the screen, a plausible-looking answer.
    nonisolated static func primaryHeight(among screens: [UpRect]) -> CGFloat? {
        guard let primary = screens.first(where: { $0.contains(.zero) }) ?? screens.first else { return nil }
        return primary.size.height
    }
}

/// The `NSEvent` monitors hover listens through.
@MainActor
final class SystemHoverEvents: HoverEventSource {
    private var monitors: [Any] = []

    /// Movement and modifiers both: watching movement alone would never fire for a reader who parks the pointer on a
    /// word and *then* presses the key. The rest are watched only to cancel a pending tap; none of them starts a lookup.
    static let watched: [NSEvent.EventTypeMask] = [
        .mouseMoved, .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    func start(_ handler: @escaping @MainActor (HoverEvent) -> Void) -> Bool {
        guard monitors.isEmpty else { return true }
        for mask in Self.watched {
            guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
                // A global monitor's event has no window, so its location is already on screen.
                let mapped = Self.event(type: event.type, flags: event.modifierFlags, timestamp: event.timestamp,
                                        location: UpPoint(event.locationInWindow))
                MainActor.assumeIsolated { if let mapped { handler(mapped) } }
            }) else {
                // **A partial install is a failure**: rolled back, so a retry means something.
                stop()
                return false
            }
            monitors.append(monitor)
        }
        return true
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    /// An AppKit event as hover sees it. **Anything that is not a modifier or a movement is other input.**
    nonisolated static func event(
        type: NSEvent.EventType, flags: NSEvent.ModifierFlags, timestamp: TimeInterval, location: UpPoint? = nil
    ) -> HoverEvent? {
        switch type {
        case .mouseMoved: .pointerMoved
        case .flagsChanged: .modifiers(HoverWatcher.modifiers(of: flags), at: timestamp, location: location)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel: .otherInput
        default: nil
        }
    }
}
