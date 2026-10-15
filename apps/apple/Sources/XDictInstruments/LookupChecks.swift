import Foundation
import XDictContract
import XDictLibrary
import XDictSearch

/// The lookup scenario's checks (`LookupScenario`), one per clause of WI-6's done-when.
extension LookupScenario {
    // MARK: - Scope and order (Q1, Q2)

    /// `scope.changesResults`: every enabled dictionary that has `apple` answers it (Alpha and Beta of the generated
    /// ones), then only the one the scope names, then every one again. The driver reads the toolbar's scope while it
    /// names one (`scope`).
    func scope(_ findings: inout Findings) async {
        await search("apple")
        let every = answeredNames, generated = answeredGenerated
        await search("apple", scope: ids["beta"].map(SearchScope.one) ?? .all)
        let one = answeredNames, shown = model.sections.map(\.name)
        findings.merge(await stage.checkpoint("scope"))
        await search("apple")
        let again = answeredNames
        findings.check("scope.changesResults", generated == ["Alpha", "Beta"] && one == ["Beta"] && shown == ["Beta"]
                       && again == every,
                       "every enabled dictionary: \(every); scope Beta: \(one) (sections \(shown)); every again: \(again)")
    }

    /// `order.followsTheLibrary`: Alpha moved below Beta in the library puts Beta's results first, and back.
    func order(_ findings: inout Findings) async {
        guard let alpha = ids["alpha"] else {
            findings.check("order.followsTheLibrary", false, "no Alpha")
            return
        }
        await search("apple")
        let before = answeredGenerated
        library.moveDown(alpha)
        model.sourcesDidChange()
        await settle()
        let after = answeredGenerated
        let hits = model.sections.compactMap { section -> String? in
            if case .results(let results) = section.status { "\(section.name): \(describe(results.hits))" } else { nil }
        }
        findings.merge(await stage.checkpoint("order"))
        library.moveUp(alpha)
        model.sourcesDidChange()
        await settle()
        let restored = answeredGenerated
        findings.check("order.followsTheLibrary", before == ["Alpha", "Beta"] && after == ["Beta", "Alpha"]
                       && restored == before,
                       "before \(before); Alpha moved down: \(after) (\(hits.joined(separator: "; "))); moved back: \(restored)")
    }

    // MARK: - Folding (Q4) and links (I7)

    /// `folding.exactLeads`: in Alpha, typed `abbe` finds `abbe` (exact) before `abbé` (marks dropped), each with its
    /// reason; Beta, which has only `abbé`, finds it. `folding.readerModeOnly`: Beta's link to `abbe`, looked up in
    /// link mode, finds nothing there.
    func folding(_ findings: inout Findings) async {
        await search("abbe")
        let alpha = results("alpha")?.hits, beta = results("beta")?.hits
        let leads = alpha.map { $0.map(\.headword) } == ["abbe", "abbé"] && alpha?.first?.how == .exact
            && alpha?.last?.how == .unmarked
        findings.merge(await stage.checkpoint("folding"))
        findings.check("folding.exactLeads", leads && beta.map { $0.map(\.headword) } == ["abbé"]
                       && beta?.first?.how == .unmarked,
                       "Alpha: \(describe(alpha)); Beta: \(describe(beta))")

        guard let betaID = ids["beta"] else { return }
        model.follow("abbe", anchor: nil, from: betaID)
        await settle()
        let linked = model.lookup, status = section("beta")?.status
        let direct = await lookup("abbe", in: "beta", mode: .link)
        model.back()
        await settle()
        findings.check("folding.readerModeOnly", linked?.mode == .link && linked?.scope == .one(betaID)
                       && status == .noMatch(query: "abbe", mode: .link) && direct?.total == 0
                       && model.lookup?.query == "abbe" && model.lookup?.mode == .reader,
                       "Beta's link to abbe: looked up as \(String(describing: linked?.mode)) in "
                       + "\(String(describing: linked?.scope)), Beta \(String(describing: status)); asked directly in "
                       + "link mode: \(direct.map { "\($0.total) hits" } ?? "no answer"); Back to "
                       + "\(model.lookup?.query ?? "nothing") (\(String(describing: model.lookup?.mode)))")
    }

    // MARK: - Phrases and internal keys (Q6, Q7)

    /// `phrase.resolvesIntact`: `take off` finds the key `take off`, not `take`. `phrase.suggested`: typing `take o`
    /// suggests `take off` and `take on`.
    func phrase(_ findings: inout Findings) async {
        await search("take off")
        let hits = results("alpha")?.hits
        findings.check("phrase.resolvesIntact", hits.map { $0.map(\.headword) } == ["take off"]
                       && hits?.first?.how == .exact, "Alpha for take off: \(describe(hits))")
        model.text = "take o"
        model.textDidChange()
        let came = await until(Self.step) { !self.model.suggestions.isEmpty }
        let offered = model.suggestions
        findings.merge(await stage.checkpoint("suggestions"))
        model.dismissSuggestions()
        findings.check("phrase.suggested", came && offered.contains("take off") && offered.contains("take on"),
                       "typing take o suggested \(offered)")
    }

    /// `internal.neverSuggested`: Alpha's 120 `@take_box_…` keys, reached by a link, are suggested for no prefix, the
    /// window's own suggestions for `take` included. With the owner's dictionaries, `internal.ldoce`: LDOCE's `@…`
    /// keys likewise (`core-api.md` finding 8).
    func internalKeys(_ findings: inout Findings) async {
        let reached = await lookup("@take_box_000", in: "alpha", mode: .link)
        model.text = "take"
        model.textDidChange()
        let came = await until(Self.step) { !self.model.suggestions.isEmpty }
        let window = model.suggestions
        model.dismissSuggestions()
        var asked: [String: [String]] = [:]
        for prefix in ["take", "take_", "takeb", "@", "@t", "@take", "@take_box"] {
            asked[prefix] = await suggestions(prefix, in: "alpha") ?? ["(no answer)"]
        }
        let leaked = (asked.values.joined() + window).filter { $0.hasPrefix("@") || $0 == "(no answer)" }
        findings.check("internal.neverSuggested", reached.map { $0.total >= 1 } == true && came && leaked.isEmpty
                       && window.contains("take"),
                       "@take_box_000 reached by a link: \(reached.map { "\($0.total) hit(s)" } ?? "no answer"); "
                       + "the window's suggestions for take: \(window); asked: "
                       + asked.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value.prefix(5))" }.joined(separator: "; ")
                       + "; internal or unanswered: \(leaked.prefix(5))")

        guard ids["ldoce"] != nil else { return }
        let ldoce = await lookup("@collocations_1", in: "ldoce", mode: .link)
        var offered: [String: [String]] = [:]
        for prefix in ["@", "@coll", "@collocations", "coll", "collocations", "collocations_"] {
            offered[prefix] = await suggestions(prefix, in: "ldoce") ?? ["(no answer)"]
        }
        let inside = offered.values.joined().filter { $0.hasPrefix("@") || $0 == "(no answer)" }
        findings.check("internal.ldoce", ldoce.map { $0.total >= 1 } == true && inside.isEmpty,
                       "@collocations_1 reached by a link: \(ldoce.map { "\($0.total) hit(s)" } ?? "no answer"); "
                       + offered.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value.prefix(4))" }
                       .joined(separator: "; ") + "; internal or unanswered: \(inside.prefix(5))")
    }

    // MARK: - Why nothing (Q11)

    /// `unavailable.toldApart`: for `apple`, Records has no match, Slow is indexing, Gone's file is missing, Damaged is
    /// damaged and Locked unsupported: five kinds, each with its own next action. The driver reads each one's sentence
    /// (`unavailable`). Slow is added here, its import's request held by the transport, by its file's id (which the
    /// request names, `FileSpec.name`), set before the import's task first runs. Then `unavailable.indexingEnds`.
    func unavailable(_ findings: inout Findings) async {
        ids["slow"] = library.add([work.appending(path: "slow/slow.mdx")]).first
        let slowFiles = Set(library.entries.first { $0.id == ids["slow"] }?.files.map(\.id.uuidString) ?? [])
        hold.hold("slow.import", at: .request) { operation in
            if case .importPackage(let spec) = operation { spec.files.contains { slowFiles.contains($0.name) } } else { false }
        }
        let held = await until(Self.step) { self.hold.heldCount("slow.import") > 0 }
        model.sourcesDidChange()
        await search("apple")
        let wanted: [(String, (SectionStatus?) -> Bool, NextAction?)] = [
            ("records", { $0 == .noMatch(query: "apple", mode: .reader) }, .checkSpelling),
            ("slow", { if case .unavailable(.indexing)? = $0 { true } else { false } }, .wait),
            ("gone", { $0 == .unavailable(.missingFile("gone.mdx")) }, ids["gone"].map(NextAction.openLibrary)),
            ("damaged", { $0 == .unavailable(.malformed) }, ids["damaged"].map(NextAction.openLibrary)),
            ("locked", { $0 == .unavailable(.unsupported(.registrationCode)) }, ids["locked"].map(NextAction.openLibrary)),
        ]
        var wrong: [String] = [], seen: [String] = []
        for (name, ok, next) in wanted {
            let section = section(name)
            seen.append("\(name): \(section.map { String(describing: $0.status) } ?? "no section"), next "
                        + "\(section?.next.map { String(describing: $0) } ?? "none")")
            if !ok(section?.status) || section?.next != next { wrong.append(name) }
        }
        // Each one alone in scope, so the driver reads its sentence at the top of the list, where it is drawn.
        for (name, _, _) in wanted {
            guard let id = ids[name] else { continue }
            await search("apple", scope: .one(id))
            findings.merge(await stage.checkpoint("unavailable.\(name)"))
        }
        model.setScope(.all)
        findings.check("unavailable.toldApart", held && wrong.isEmpty && Set(seen).count == wanted.count,
                       "Slow's import held: \(held); \(seen.joined(separator: "; ")); wrong: \(wrong)")
        await indexingEnds(&findings)
    }

    /// `unavailable.indexingEnds`: Slow's import, let go at last, completes; then Slow answers like any other.
    func indexingEnds(_ findings: inout Findings) async {
        hold.release("slow.import")
        let settled = await library.settled(within: .seconds(60))
        model.sourcesDidChange()
        await search("slow")
        let hits = results("slow")?.hits
        findings.check("unavailable.indexingEnds", settled && hits.map { $0.map(\.headword) } == ["slow"],
                       "settled \(settled); Slow \(describe(ids["slow"].flatMap { library.phases[$0] })), its answer "
                       + "for slow: \(describe(hits))")
    }

    // MARK: - A slow dictionary (Q12)

    /// `delay.othersNotHeld`: with Alpha's replies held by the transport, Beta's answer is shown while Alpha is still
    /// searching (the driver reads both, `delay`); let go, Alpha's answer follows. `delay.entryKeepsTheOrder`: the entry
    /// shown waits for Alpha, the earlier dictionary, rather than taking Beta's quicker answer.
    func delay(_ findings: inout Findings) async {
        guard let alpha = ids["alpha"].flatMap(library.handle), let alphaID = ids["alpha"], let betaID = ids["beta"] else {
            findings.check("delay.othersNotHeld", false, "Alpha or Beta does not answer")
            return
        }
        let times = Answers()
        model.onAnswered = { id, _ in times.at[id] = times.at[id] ?? .now }
        defer { model.onAnswered = nil }
        hold.hold("alpha.replies", at: .reply) { operation in
            if case .lookup(_, let dicts, _) = operation { dicts.contains(alpha) } else { false }
        }
        model.setScope(.all)
        model.text = "apple"
        let started = ContinuousClock.now
        model.submit()
        let betaCame = await until(Self.step) { times.at[betaID] != nil }
        let whileHeld = (alpha: section("alpha")?.status, beta: results("beta")?.hits.count ?? 0,
                         shown: model.shown?.result.dictionary, held: hold.heldCount("alpha.replies"))
        findings.merge(await stage.checkpoint("delay"))
        let stillHeld = times.at[alphaID] == nil
        let released = ContinuousClock.now
        hold.release("alpha.replies")
        let alphaCame = await until(Self.step) { times.at[alphaID] != nil }
        _ = await until(Self.step) { self.model.shown != nil }
        await settle()
        let betaAfter = times.at[betaID].map { $0 - started }, alphaAfter = times.at[alphaID].map { $0 - started }
        findings.check("delay.othersNotHeld", betaCame && whileHeld.alpha == .searching && whileHeld.beta > 0
                       && whileHeld.held >= 1 && stillHeld && alphaCame && times.at[alphaID].map { $0 >= released } == true
                       && results("alpha") != nil,
                       "Beta answered after \(betaAfter.map { milliseconds($0) } ?? "never") ms with \(whileHeld.beta) "
                       + "hit(s) while Alpha was \(String(describing: whileHeld.alpha)) (\(whileHeld.held) reply held); "
                       + "Alpha answered after \(alphaAfter.map { milliseconds($0) } ?? "never") ms, once let go, with "
                       + "\(describe(results("alpha")?.hits))")
        findings.check("delay.entryKeepsTheOrder", whileHeld.shown != betaID && model.shown?.result.dictionary == alphaID,
                       "while Alpha was held the entry shown was "
                       + "\(whileHeld.shown.map { model.source($0)?.name ?? "?" } ?? "none"); once it answered, "
                       + "\(model.shown.map { model.source($0.result.dictionary)?.name ?? "?" } ?? "none")")
    }

    // MARK: - Every record (Q10)

    /// `paging.everyRecord`: `EC` in Records answers a first page and its total, 66,355, then page after page until
    /// every record is loaded, each once, in order, every row naming its record.
    func paging(_ findings: inout Findings) async {
        guard let records = ids["records"] else {
            findings.check("paging.everyRecord", false, "no Records")
            return
        }
        await search("EC", scope: .one(records))
        let first = results("records")
        findings.merge(await stage.checkpoint("paging"))
        let began = ContinuousClock.now
        // Bounded by progress, not by the clock: a page that fails (on a heavily loaded Mac, one passing the client's
        // 5 s lookup deadline) is asked again, as the reader's Retry would, and only `pageAttempts` failures in a row at
        // the same offset end the walk. A page that never comes, or comes short, still fails the check below.
        var pages = 1, failuresInARow = 0, retried = 0
        var lastFailure: LookupFailure?
        while let now = results("records"), now.hasMore {
            let had = now.hits.count
            model.loadMore(records)
            await settle()
            let after = results("records")
            if (after?.hits.count ?? 0) > had {
                pages += 1
                failuresInARow = 0
            } else if let failure = after?.moreFailed, failuresInARow + 1 < Self.pageAttempts {
                lastFailure = failure
                failuresInARow += 1
                retried += 1
            } else {
                lastFailure = after?.moreFailed ?? lastFailure
                break
            }
        }
        let all = results("records")
        let occurrences = all?.hits.map(\.entry.occurrence) ?? []
        let inOrder = occurrences == (0..<UInt32(Self.records)).map { $0 }
        findings.check("paging.everyRecord", first?.hits.count == 100 && first?.total == UInt64(Self.records)
                       && all?.hits.count == Self.records && inOrder && all?.hasMore == false
                       && all?.repeatedKeys == ["EC"] && all?.hits.allSatisfy { $0.headword == "EC" } == true,
                       "first page \(first?.hits.count ?? 0) of \(first?.total ?? 0); after \(pages) page(s) in "
                       + "\(milliseconds(ContinuousClock.now - began)) ms: \(all?.hits.count ?? 0) loaded, each record once "
                       + "in order: \(inOrder), more: \(all?.hasMore ?? true), keys shown with their record: "
                       + "\(all?.repeatedKeys.sorted() ?? []), pages asked again: \(retried), last failure: "
                       + "\(lastFailure.map { String(describing: $0) } ?? "none")")
        await search("apple")
    }

    // MARK: - The trail (I7, I8)

    /// `link.followedInLinkMode`: each of five links, `hop0` to `hop5`, is looked up in link mode in Alpha, its own
    /// dictionary, and shown. `trail.backReturnsExactly`: Back five times returns to each entry before, at the place it
    /// was scrolled to. `trail.forwardReturnsExactly`: Forward five times, likewise. `trail.originInOneStep`: from the
    /// fifth hop, one step returns to `hop0`, the word typed, where it was.
    func trail(_ findings: inout Findings) async {
        guard let alphaID = ids["alpha"] else {
            findings.check("link.followedInLinkMode", false, "no Alpha")
            return
        }
        await search("hop0")
        let start = model.trail.index
        var places: [(query: String, result: ResultID?, offset: Double?)] = []
        var links: [String] = [], landedAll = true
        for hop in 0...Self.hops {
            if hop > 0 {
                model.follow("hop\(hop)", anchor: nil, from: alphaID)
                await settle()
                let lookup = model.lookup
                links.append("hop\(hop): \(String(describing: lookup?.mode)) in "
                             + "\(lookup.map { String(describing: $0.scope) } ?? "?") → \(model.shown?.result.entry.key ?? "nothing")")
                if lookup?.mode != .link || lookup?.scope != .one(alphaID) || model.shown?.result.entry.key != "hop\(hop)" {
                    landedAll = false
                }
            }
            guard let shown = model.shown, await stage.landed(shown) else {
                landedAll = false
                places.append(("hop\(hop)", model.shown?.result, nil))
                continue
            }
            let offset = await stage.scroll(to: Double(150 + 90 * hop))
            places.append(("hop\(hop)", shown.result, offset))
        }
        findings.check("link.followedInLinkMode", landedAll && links.count == Self.hops, links.joined(separator: "; "))

        func here() async -> (query: String, result: ResultID?, offset: Double?) {
            await settle()
            guard let shown = model.shown, await stage.landed(shown) else { return (model.lookup?.query ?? "", nil, nil) }
            return (model.lookup?.query ?? "", shown.result, await stage.offset())
        }
        func same(_ a: (query: String, result: ResultID?, offset: Double?),
                  _ b: (query: String, result: ResultID?, offset: Double?)) -> Bool {
            guard let x = a.offset, let y = b.offset else { return false }
            return a.query == b.query && a.result == b.result && a.result != nil && abs(x - y) <= 2
        }
        func say(_ place: (query: String, result: ResultID?, offset: Double?)) -> String {
            "\(place.query) at \(place.offset.map { String(format: "%.0f", $0) } ?? "?")"
        }

        var back: [String] = [], backOK = true
        for index in stride(from: Self.hops - 1, through: 0, by: -1) {
            model.back()
            let now = await here()
            back.append("\(say(now)) (was \(say(places[index])))")
            if !same(now, places[index]) { backOK = false }
        }
        let visits = model.trail.visits.indices.filter { $0 >= start - 1 }.map { index in
            let visit = model.trail.visits[index]
            return "\(index): \(visit.query)→\(visit.result?.entry.key ?? "none")"
        }
        findings.check("trail.backReturnsExactly", backOK && places.count == Self.hops + 1 && model.trail.index == start,
                       back.joined(separator: "; ") + "; at place \(model.trail.index) of \(start)…: "
                       + visits.joined(separator: ", "))

        var forward: [String] = [], forwardOK = true
        for index in 1...Self.hops {
            model.forward()
            let now = await here()
            forward.append("\(say(now)) (was \(say(places[index])))")
            if !same(now, places[index]) { forwardOK = false }
        }
        findings.check("trail.forwardReturnsExactly", forwardOK && !model.canGoForward, forward.joined(separator: "; "))

        let from = model.trail.index
        model.returnToOrigin()
        let origin = await here()
        findings.check("trail.originInOneStep", same(origin, places[0]) && model.lookup?.mode == .reader
                       && model.trail.index == start && from == start + Self.hops,
                       "from place \(from), one step: \(say(origin)) (typed: \(say(places[0]))), in "
                       + "\(String(describing: model.lookup?.mode)) mode")
    }
}

/// When each dictionary's answer was stored, as the model reports it.
@MainActor
final class Answers {
    var at: [UUID: ContinuousClock.Instant] = [:]
}
