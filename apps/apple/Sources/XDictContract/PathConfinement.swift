import Foundation

/// **Where a path the contract carries may lead** (audit 2026-11-05 L1). Three operations name places on disk, which
/// the core opens or writes as given: `setWordPack(path:)`, `buildWordPack(sources:manifest:output:)` and
/// `ledgerSync(input:output:)`. Their designated folders are the app group's (`AppGroup.wordPack`, `AppGroup.sync`);
/// a folder outside the service's sandbox is closed to it by the sandbox. What the sandbox leaves open is **the
/// service's own container** — its registry, the ledger inside it, its indexes and the rest of its state — so a path
/// into it is refused here, before the core is asked, as is a path that is not absolute, that takes a `..` step, or
/// whose existing part cannot be resolved (a dangling link). The existing part of a path is resolved, links included,
/// before it is compared, so a link the app group holds cannot lead into the container.
///
/// **Defence in depth, not the boundary**: the client is code-sign gated (`ClientCheck`), and a link swapped in after
/// this check is not seen; the core opening what it was given is the last word.
public struct PathConfinement: Hashable, Sendable {
    /// The folders no path may lead into, as given.
    public let forbidden: [String]

    public init(forbidden: [URL]) {
        self.forbidden = forbidden.map { $0.path(percentEncoded: false) }
    }

    /// No folder forbidden: what a client asks with, which does not know the service's container.
    public static let unconfined = PathConfinement(forbidden: [])

    /// `path`'s refusal, or nil when it may be used.
    public func refusal(_ path: String) -> Refusal? {
        guard let resolved = Self.resolved(path) else { return .forbiddenPath }
        let target = Self.compared(resolved)
        for folder in forbidden {
            let root = Self.compared(Self.resolved(folder) ?? folder)
            if target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/") { return .forbiddenPath }
        }
        return nil
    }

    /// Compared without regard to case or composition: the container's volume is case-insensitive by default, and a
    /// path that differs only so names the same folder. On a case-sensitive one this refuses more, never less.
    private static func compared(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// **The path as the file system would follow it**: its longest existing part resolved with every link, then the
    /// rest, which does not exist yet and so holds no link. Nil for a path that is not absolute, takes a `..` step, or
    /// whose existing part cannot be resolved — a dangling link among it.
    static func resolved(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let steps = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !steps.contains("..") else { return nil }
        var existing = steps
        var rest: [String] = []
        while true {
            let prefix = "/" + existing.joined(separator: "/")
            var info = stat()
            if lstat(prefix, &info) == 0 {
                guard let real = realpath(prefix, nil) else { return nil }
                defer { free(real) }
                let base = String(cString: real)
                guard !rest.isEmpty else { return base }
                return (base == "/" ? "" : base) + "/" + rest.reversed().joined(separator: "/")
            }
            // The root always exists, so the walk ends there at the latest.
            guard let last = existing.popLast() else { return nil }
            rest.append(last)
        }
    }
}

extension ServiceOperation {
    /// **The places on disk this operation names** (`PathConfinement`): empty for every operation but the three that
    /// carry a path. A package's files travel as handles and are not among them.
    public var paths: [String] {
        switch self {
        case .setWordPack(let path): [path]
        case .buildWordPack(let sources, let manifest, let output): [sources, manifest, output]
        case .ledgerSync(let input, let output, _): [input, output]
        // Exhaustive on purpose: an operation added later says here whether it carries a path.
        case .versions, .importPackage, .cancel, .openPackage, .close, .lookup, .suggest, .words, .explore, .collocates,
             .wordPack, .clearWordPack, .examples, .examplesBuild, .phrases, .phrasesBuild, .entry, .link, .resource,
             .joinLineage, .splitLineage, .lineageOf, .health, .readingStyle, .convertApple, .cancelConversion,
             .displayOptions, .entryText, .entryGloss, .ledgerRecord, .ledgerHistory, .studyNote, .studyNotes,
             .reviewQueue, .reviewGrade, .reviewUndo, .reviewSummary, .definitionHash, .studyReanchor, .studyNoteAt,
             .exportData, .eraseData, .studyConflicts, .reviewResolve, .ledgerRemove, .ledgerRestore:
            []
        }
    }
}
