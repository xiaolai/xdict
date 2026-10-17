import Foundation
import XDictClient
import XDictContract
import XDictLibrary

extension LibraryScenario {
    // MARK: - Languages (L3)

    func languages(_ library: Library, _ findings: inout Findings) async {
        _ = library.add([work.appending(path: "lang")])
        await library.settle("lang", within: Self.step, &findings)
        let stated = library.entries.first { $0.mdx?.fileName == "牛津高阶英汉双解词典.mdx" }
        let plain = library.entries.first { $0.mdx?.fileName == "Plain Glossary.mdx" }
        findings.check("languages.statedNotAsked", stated?.languages.pair == LanguagePair(search: "en", explanation: "zh-Hans")
                       && stated?.languages.needsAsking == false && stated?.displayName == "牛津高阶英汉双解词典",
                       "\(stated.map { "\($0.languages), shown as \($0.displayName)" } ?? "not added")")
        findings.check("languages.guessAsked", plain?.languages.needsAsking == true
                       && plain?.languages.pair == LanguagePair(search: "en", explanation: "en"),
                       "\(plain.map { "\($0.languages)" } ?? "not added")")
        guard let plain else {
            findings.check("languages.editPersists", false, "Plain Glossary was not added")
            return
        }
        let edit = LanguagePair(search: "en", explanation: "fr")
        library.setLanguages(plain.id, edit)
        let stored = (try? LibraryStore(directory: storeDirectory).load())?.entries.first { $0.id == plain.id }?.languages
        findings.check("languages.editPersists", stored?.pair == edit && stored?.confirmed == true
                       && stored?.needsAsking == false, "read back from the library's file: \(stored.map { "\($0)" } ?? "none")")
    }

    // MARK: - Refusals, links out, sounds

    func refusals(_ library: Library, _ findings: inout Findings) async {
        _ = library.add([work.appending(path: "refused")])
        await library.settle("refused", within: Self.step, &findings)
        func entry(_ name: String) -> LibraryEntry? { library.entries.first { $0.mdx?.fileName == name } }
        let v3 = entry("v3.mdx"), locked = entry("regcode.mdx"), damaged = entry("damaged.mdx")
        findings.check("refusal.resourceLibraryV3", v3.map { library.phases[$0.id] == .ready } == true
                       && v3?.notes == [.volumeUnreadable(fileName: "v3.mdd", reason: .resourceLibraryV3)],
                       "phase \(describe(v3.flatMap { library.phases[$0.id] })), notes \(v3?.notes ?? [])")
        // A registration code is not a refusal kept with the dictionary: the file is not added at all, and said so once.
        findings.check("refusal.registrationCode", locked == nil && library.notices.contains(.locked(fileName: "regcode.mdx")),
                       "entry \(locked.map { "kept, phase \(describe(library.phases[$0.id]))" } ?? "not added"), notices "
                       + "\(library.notices)")
        findings.check("refusal.damaged", damaged.map { library.phases[$0.id] == .refused(.damaged) } == true
                       && damaged?.refusal == .damaged, "phase \(describe(damaged.flatMap { library.phases[$0.id] }))")
        findings.fact("refusals", [v3?.notes.first.map { "\($0)" }, locked?.refusal.map { "\($0)" },
                                   damaged?.refusal.map { "\($0)" }].compactMap { $0 }.joined(separator: "; "))

        let esc = await add(library, "escape", &findings)
        let escaped = library.entries.first { $0.id == esc }
        let css = await resource(library.handle(esc), "esc.css")
        findings.check("escape.refused", escaped?.notes == [.outsideChosenFolder(fileName: "esc.css")]
                       && escaped?.files.contains { $0.fileName == "esc.css" } == false
                       && css?.resource == .missing(path: "esc.css") && library.phases[esc] == .ready,
                       "notes \(escaped?.notes ?? []), files \(escaped?.files.map(\.fileName) ?? []), esc.css "
                       + "\(css.map { "\($0.resource)" } ?? "none")")

        let sounds = await add(library, "sounds", &findings)
        var told: [String: SoundDiagnosis] = [:]
        for path in ["here.mp3", "present.spx", "gone.mp3"] {
            if let fetched = await resource(library.handle(sounds), path) { told[path] = SoundDiagnosis.of(fetched.resource) }
        }
        findings.check("sounds.toldApart", told["here.mp3"] == .playable && told["present.spx"] == .unsupported(format: "spx")
                       && told["gone.mp3"] == .missing(path: "gone.mp3"), "\(told.sorted { $0.key < $1.key })")
    }

    // MARK: - A changed edition (L5, ADR-0002 decision 3)

    func changed(_ library: Library, _ findings: inout Findings) async {
        let folder = work.appending(path: "rw"), file = folder.appending(path: "rewrite.mdx")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: work.appending(path: "rewrite/first.mdx"), to: file)
        } catch {
            return findings.check("changed.newEdition", false, "the first edition could not be placed: \(error)")
        }
        let id = await add(library, "rw", &findings)
        let second = work.appending(path: "rewrite/second.mdx")
        await ChangedEdition(client: client, store: LibraryStore(directory: storeDirectory), prefix: "changed", limit: Self.step)
            .check(library, id: id, rewrite: { beside in try FileManager.default.copyItem(at: second, to: beside) }, &findings)
    }

    // MARK: - A moved folder (L5)

    /// The `folder` package's folder moved; the library read again from a copy of its file: found by relinking, and
    /// missing without (the positive control).
    func relink(_ findings: inout Findings) async {
        let off = scratch.appending(path: "store-unlinked"), on = scratch.appending(path: "store-relinked")
        do {
            for copy in [off, on] {
                try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: storeDirectory.appending(path: LibraryStore.fileName),
                                                 to: copy.appending(path: LibraryStore.fileName))
            }
            try FileManager.default.moveItem(at: work.appending(path: "folder"), to: work.appending(path: "folder-moved"))
        } catch {
            return findings.check("relink.followsAMove", false, "the folder could not be moved: \(error)")
        }
        let unlinked = Library(store: LibraryStore(directory: off), backend: client, options: Library.Options(relinking: false))
        await unlinked.start()
        await unlinked.settle("relink.off", within: Self.step, &findings)
        let lost = unlinked.entries.first { $0.mdx?.fileName == "vol.mdx" }
        findings.check("relink.controlWithoutRelinking", lost.flatMap { unlinked.phases[$0.id] } == .missing(fileName: "vol.mdx"),
                       "without relinking: \(describe(lost.flatMap { unlinked.phases[$0.id] }))")
        let relinked = Library(store: LibraryStore(directory: on), backend: client)
        await relinked.start()
        await relinked.settle("relink.on", within: Self.step, &findings)
        let found = relinked.entries.first { $0.mdx?.fileName == "vol.mdx" }
        let shared = await resource(found.flatMap { relinked.handle($0.id) }, "shared.bin")
        findings.check("relink.followsAMove", found.map { relinked.phases[$0.id] == .ready } == true
                       && found?.mdx?.location.path.contains("/folder-moved/") == true
                       && shared?.text == "shared from volume 0",
                       "\(describe(found.flatMap { relinked.phases[$0.id] })) at \(found?.mdx?.location.path ?? "none")")
    }
}
