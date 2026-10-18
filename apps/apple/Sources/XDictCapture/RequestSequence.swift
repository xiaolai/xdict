/// Capture's request numbers — **handing one out and claiming presentation are two acts** (XiaolaiDict ADR-0045).
///
/// A hover is given its number when the reader's gesture is accepted, before the screen is read,
/// so that its place in line is the moment the reader asked. It claims presentation only once a word
/// has been read, and the claim fails if a later request got there first. Minting the claim at the
/// gesture instead would be wrong in the other direction: under hold, every twitch of the pointer on
/// the word already shown passes the gate and ends `.samePlace`, and each would have invalidated what
/// the consumer is still showing.
///
/// A value, so the rule is tested without a window and the test's stand-in cannot drift from it.
public struct RequestSequence: Sendable, Equatable {
    /// The last number handed out.
    public private(set) var issued = 0
    /// No number at or below this may claim presentation: it has been claimed past, or closed over.
    private var floor = 0
    /// The request whose result is presented, if any.
    public private(set) var current: Int?

    public init() {}

    /// A new number, which supersedes nothing until it is claimed.
    public mutating func begin() -> Int {
        issued += 1
        return issued
    }

    /// Takes presentation for `request`, and answers whether it did. Refused once a later request has
    /// claimed it or presentation has been closed since `request` was handed out.
    public mutating func claim(_ request: Int) -> Bool {
        guard request > floor, request <= issued else { return false }
        floor = request
        current = request
        return true
    }

    /// Begins and claims at once — for a request the reader made where there is no wait for anything to
    /// overtake it: the selection shortcut, a Service, a menu.
    public mutating func next() -> Int {
        let request = begin()
        floor = request
        current = request
        return request
    }

    /// Closing supersedes every request handed out so far, claimed or not: a result that arrives
    /// afterwards is not presented over the reader's dismissal.
    public mutating func close() {
        floor = issued
        current = nil
    }

    public func isCurrent(_ request: Int) -> Bool { current == request }
}
