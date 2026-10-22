import Foundation

/// **A sense the reader clicked in an entry** (plan-explain-sense WI-5; ADR-0029 d.2): the ordinal the core wrote as
/// `data-xdict-sense`, and nothing else. It comes from the shell's own script (`sense-clicks.js`) through a page the
/// dictionary wrote, so it is taken only as one bounded ordinal: `{kind: "sense", id}` and nothing else, an integer from
/// 1 through `maximumID`. The sense's text is read from the core's projection, never from the page.
public struct EntrySenseClick: Equatable, Sendable {
    /// The native bound, held again here; the core's own ordinal cap.
    public static let maximumID: UInt32 = 1_000_000

    public let id: UInt32

    public init?(message body: Any) {
        guard let body = body as? [String: Any], body.count == 2, body["kind"] as? String == "sense",
              let number = body["id"] as? NSNumber else { return nil }
        // **A boolean is an NSNumber**: `true` would otherwise pass as 1. Only an integral number is an ordinal.
        guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value == value.rounded(), value >= 1, value <= Double(Self.maximumID) else { return nil }
        self.id = UInt32(value)
    }
}
