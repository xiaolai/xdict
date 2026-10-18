import Foundation

/// The limits each side enforces on the other: frozen with the contract (a receiver refuses past them).
public enum Limits {
    /// **64 MiB per resource reply**: the core's own ceiling (`MAX_RESOURCE_BYTES`, one reader block, `core.rs`), which no
    /// MDD record can exceed. Spike 2 carried 63 MiB whole and hash-equal through service, handler and page on both Macs;
    /// XPC added no copy in the service, so whole replies, no chunking. Only resources the view does not render.
    public static let maxResourceBytes: UInt64 = 64 << 20

    /// **16 MiB per rendered body** (an entry, or a resource the view renders, `isRenderedByTheView`): five times the
    /// largest record in the 25 (OED, 3,344,260 bytes; spike 2), room for the rewrite to grow it. A 16 MB entry already
    /// cost ~1 GB of WebContent to render and a 62 MB one 3.3 GB (spike 2), so the reader's views ask for no more.
    public static let maxBodyBytes: UInt64 = 16 << 20

    /// **4 MiB per JSON envelope** (request, reply, event), refused before it is decoded (Codex objection 2): payloads
    /// travel beside the JSON, so only references and keys are in it. The largest legitimate one is a page of 1,000 hits
    /// whose redirect chains are at the core's hop limit (8 hops) through 100-character keys, about 2.3 MB
    /// (`LimitsTests.aFullPageOfTheLongestHitsFits`); a lookup over 300 dictionaries of 4 files, with a token each, is
    /// about 0.25 MB.
    public static let maxEnvelopeBytes: UInt64 = 4 << 20

    /// **64 files per package** (Codex objection 2): an import indexes each volume on a thread of its own (`core.rs`
    /// `index_all`), and every file of an open package holds a descriptor in the service, whose soft limit launchd sets
    /// at 256 (`launchctl limit maxfiles`, build Mac, 2026-10-14). An MDict package is one MDX, its volumes and a few
    /// loose files; 64 is room for that, a quarter of the descriptors, not a measured maximum.
    public static let maxPackageFiles = 64

    /// **100 suggestions per call**: a search field shows a screenful and scrolls a few more. The core's own cap is
    /// `MAX_SUGGEST`, 1,000, the size of a page; before it, `suggest` had none (Codex objection 2).
    public static let maxSuggestions: UInt32 = 100

    /// **2 bulk calls (entry, resource) per connection at once**: four 63 MiB replies at once peaked the service at
    /// 1.75 GB (spike 2); two should hold it near 0.9 GB (interpolated, not measured). Counted by `Credits`.
    public static let bulkCallsInFlight = 2

    /// **4 lookup-class calls (open, lookup, suggest, link) per connection at once** (Codex objection 2): one lookup may
    /// read 256 MiB of records and a million candidates (`core.rs` `LOOKUP_BYTES`, `LOOKUP_CANDIDATES`), so four bound
    /// that at 1 GiB of reads. The client paints each dictionary as it answers (Q12) from its own queue of lookups, four
    /// sent at a time. Counted by `Credits`.
    public static let lookupCallsInFlight = 4

    /// The media types the entry view renders as a document or a body, held to the view's ceiling like an entry (Codex
    /// objection 9: the core holds HTML, CSS and JavaScript to it, but not SVG, which the view navigates to).
    public static let renderedTypes: Set<String> = [
        "text/html", "image/svg+xml", "application/xhtml+xml", "text/xml", "application/xml", "text/css", "text/javascript",
    ]

    /// Whether a resource of type `mime` is one the view renders: its essence (before any `;`), case aside.
    public static func isRenderedByTheView(mime: String) -> Bool {
        let essence = mime.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return renderedTypes.contains(essence.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The most the payload beside `answer` to `operation` may be, checked by the client before anything sees the
    /// bytes: the view's ceiling for an entry and for a resource it renders, the core's 64 MiB for any other resource;
    /// nil for an answer that carries none.
    public static func payloadCeiling(for operation: ServiceOperation, answer: Answer) -> UInt64? {
        let viewCeiling = operation.render?.maxBodyBytes ?? maxBodyBytes
        switch answer {
        case .entry: return viewCeiling
        case .resource(.found(_, let mime)): return isRenderedByTheView(mime: mime) ? viewCeiling : maxResourceBytes
        case .versions, .imported, .cancellation, .opened, .closed, .page, .suggestions, .link, .resource(.missing),
             .lineage, .health, .readingStyle, .converted, .displayOptions: return nil
        }
    }

    static func envelopeRefusal(_ envelope: Data) -> Refusal? {
        let bytes = UInt64(envelope.count)
        return bytes > maxEnvelopeBytes ? .envelopeTooLarge(bytes: bytes, limit: maxEnvelopeBytes) : nil
    }
}

/// The two kinds of credit a connection holds (`ServiceOperation.creditClass`).
public enum CreditClass: String, Hashable, Sendable {
    /// An entry or a resource: `Limits.bulkCallsInFlight`.
    case bulk
    /// An open, a lookup, a suggestion or a link: `Limits.lookupCallsInFlight`.
    case lookup
}

/// One credit taken by `Credits.take`, given back once with `Credits.release` when the call has answered.
public struct Credit: Hashable, Sendable {
    let creditClass: CreditClass?
}

/// **What one connection may have running at once** (Codex objections 2 and 11). The service keeps one `Credits` for
/// each connection it accepts, and takes from it, under that connection's lock, before a call reaches the core; a call
/// past its class's credits is `refused(.tooManyInFlight)`. Calls of no class (versions, close, cancel, import, the
/// lineage calls) are not counted.
///
/// **Credits belong to the connection, and so does recovery.** A credited call holds its credit until the service
/// answers, which a stalled read may delay without end, so when one passes its deadline the client abandons that
/// connection and opens another (`Deadlines.abandonsConnectionOnExpiry`), which starts with every credit; the old count
/// goes with the old connection. The abandoned calls still run to their end in the service, since the core cannot stop
/// a read: until they do, the service may run more than `Limits.bulkCallsInFlight` bulk calls in all. Whether a service
/// whose connection ends with bulk work in flight exits, ending that work, is WI-3's decision.
public struct Credits: Hashable, Sendable {
    private var bulk = 0
    private var lookups = 0

    public init() {}

    /// The credits of `creditClass` now taken.
    public func inFlight(_ creditClass: CreditClass) -> Int {
        switch creditClass {
        case .bulk: bulk
        case .lookup: lookups
        }
    }

    /// The credit `operation` needs, or `tooManyInFlight`.
    public mutating func take(for operation: ServiceOperation) -> Result<Credit, Refusal> {
        switch operation.creditClass {
        case .bulk:
            guard bulk < Limits.bulkCallsInFlight else { return .failure(.tooManyInFlight) }
            bulk += 1
        case .lookup:
            guard lookups < Limits.lookupCallsInFlight else { return .failure(.tooManyInFlight) }
            lookups += 1
        case .none:
            break
        }
        return .success(Credit(creditClass: operation.creditClass))
    }

    /// Gives `credit` back. Once per credit taken; a count never goes below zero.
    public mutating func release(_ credit: Credit) {
        switch credit.creditClass {
        case .bulk: bulk = max(0, bulk - 1)
        case .lookup: lookups = max(0, lookups - 1)
        case .none: break
        }
    }
}

/// **The client's deadline for each call**, from its send (a call waiting in the client's own queue has not been
/// sent). Not on the wire, so these may be retuned without a contract bump. Each is a warm service's: the first call on
/// a new connection waits at least `coldStart`, because that call starts the service.
public enum Deadlines {
    /// **10 s, the floor for the first call on a new connection**: it launches the service, and its very first launch
    /// creates the sandbox container. Not measured (`measurements/2026-10-14-macos-xpc`, "Open": the relaunch time);
    /// WI-2's handshake deadline, kept until WI-3 measures it.
    public static let coldStart: Duration = .seconds(10)

    /// **60 s without a progress event ends an import or a health check** (neither has a deadline of its own: a 745 MB
    /// file is legitimately slow; a check reports every 4,096 records, OED's 706,524 in under a few seconds each). The core reports per 4 MiB chunk while it hashes; its silent stretches are index builds, and TLD's whole
    /// import (4.4 M keys) took 1.06 s (`measurements/2026-10-13-index-baseline`).
    public static let importSilence: Duration = .seconds(60)

    /// `operation`'s deadline, raised to `coldStart` on a fresh connection; nil for an import or a health check.
    public static func deadline(for operation: ServiceOperation, onFreshConnection: Bool) -> Duration? {
        guard let warm = warm(operation) else { return nil }
        return onFreshConnection ? max(warm, coldStart) : warm
    }

    /// **Whether a call past its deadline costs the client its connection**: yes for a call holding a credit (`Credits`),
    /// whose credit stays taken until the service answers; the client opens a new connection, with every credit, and
    /// reopens its packages there. A call holding none fails alone.
    public static func abandonsConnectionOnExpiry(_ operation: ServiceOperation) -> Bool {
        operation.creditClass != nil
    }

    static func warm(_ operation: ServiceOperation) -> Duration? {
        switch operation {
        // Bookkeeping: answered from memory, nothing read.
        case .versions, .close, .cancel, .cancelConversion: .seconds(2)
        // Headers and indexes, not bodies: reopening three packages took 1.6 ms (spike 1), paging 66,355 records 50 ms
        // (ADR-0007 row 23), 128 concurrent lookups and entries 3.6–7.3 ms (spike 1). Two orders of magnitude over the
        // worst, and five times the whole reader loop's warm p95 goal of 1 s (plan WI-10). The lineage calls read or
        // write the registry, which is no slower.
        case .openPackage, .lookup, .suggest, .link, .joinLineage, .splitLineage, .lineageOf: .seconds(5)
        // One record block read, inflated and rewritten: a 62 MB entry replied in 154 ms on the E2E Mac, 2–4× that on
        // the loaded build Mac (spike 2); the rest is room for a slow disk and one bulk call ahead in the service.
        case .entry: .seconds(10)
        // Up to 64 MiB read from the file: 164–270 ms on the E2E Mac, 785 ms on the loaded build Mac (spike 2), and 6.4 s
        // from a 10 MB/s disk; with one bulk call ahead, 15 s.
        case .resource: .seconds(15)
        // ADR-0010: at most 64 sampled entries of up to 256 KiB and the edition's sheets (up to 32 MiB) read and
        // normalized once per edition, then remembered; like a resource, bounded at 15 s.
        case .readingStyle: .seconds(15)
        // ADR-0013: the same sample of entries and the edition's sheets as the reading style reads, once per edition.
        case .displayOptions: .seconds(15)
        // Bounded by silence between progress events, not by a deadline (`importSilence`).
        case .importPackage, .health, .convertApple: nil
        }
    }
}
