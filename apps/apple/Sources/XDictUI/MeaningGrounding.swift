import Foundation
import XDictSearch

/// **Which dictionaries can answer this word** (owner, 2026-10-26: "发给它哪个词典的选项"): the All page's results, each
/// resolved to the service handle and the name the reader knows it by, in the page's own order. The pane offers them on
/// its evidence row; a choice grounds the same question in that dictionary's entry instead of whichever entry the page
/// happened to show first.
///
/// Only what the page holds now: a dictionary that has not answered yet is not offered, and one that cannot answer (no
/// open handle) never is. Off the All page there is nothing to choose: one entry is shown, and it is the one sent.
public enum MeaningGrounding {
    /// One dictionary the sentence can be answered from, with the entry this look-up found there.
    public struct Choice: Identifiable, Equatable, Sendable {
        /// The library's id for the dictionary, which is also its `SearchSource.id`.
        public let id: UUID
        public let name: String
        public let target: MeaningTarget

        public init(id: UUID, name: String, target: MeaningTarget) {
            self.id = id
            self.name = name
            self.target = target
        }
    }

    /// The choices for a page, in its order, one per dictionary that can answer.
    public static func choices(results: [ResultID], sources: [SearchSource]) -> [Choice] {
        var seen = Set<UUID>()
        return results.compactMap { result in
            guard let source = sources.first(where: { $0.id == result.dictionary }),
                  let handle = source.handle, seen.insert(source.id).inserted else { return nil }
            return Choice(id: source.id, name: source.name,
                          target: MeaningTarget(dictionary: handle, entry: result.entry))
        }
    }
}
