import Foundation
import XDictContract
import XDictLibrary

/// **What the library tells the reader, in their language** (ADR-0007 decision 10: the library hands kinds, the view
/// layer words them; AGENTS.md: a file XDict cannot read is refused with a sentence that names why). Every sentence is
/// in `Strings/Localizable.xcstrings`, in English and Simplified Chinese.
public enum LibrarySentences {
    public static func refusal(_ refusal: ImportRefusal) -> LocalizedStringResource {
        switch refusal {
        case .formatVersion(let version):
            LocalizedStringResource("This file uses MDict format \(version), which XDict does not read.")
        case .resourceLibraryV3:
            LocalizedStringResource("This resource file (.mdd) uses MDict format 3.0, which XDict cannot read yet.")
        case .registrationCode:
            LocalizedStringResource("""
                This dictionary is locked to its buyer with a registration code. XDict does not open locked \
                dictionaries.
                """)
        case .encrypted:
            LocalizedStringResource("This dictionary is encrypted in a way XDict does not read.")
        case .compression:
            LocalizedStringResource("This dictionary is compressed in a way XDict does not read.")
        case .encoding(let name):
            LocalizedStringResource("This dictionary's text is in the \(name) encoding, which XDict does not read.")
        case .damaged:
            LocalizedStringResource("This file is damaged: a checksum or its structure is wrong.")
        case .tooLarge:
            LocalizedStringResource("This file is larger than XDict can hold.")
        case .missingFile(let name):
            LocalizedStringResource("“\(name)” is not where it was, and XDict cannot find where it went.")
        case .unreadable(let name):
            LocalizedStringResource("“\(name)” could not be opened. Check that you may read it.")
        case .notAFile(let name):
            LocalizedStringResource("“\(name)” is no longer a file XDict reads: a link, a folder or a pipe has taken its place.")
        case .changedDuringImport:
            LocalizedStringResource("The file changed while XDict was reading it. Try again.")
        case .cancelled:
            LocalizedStringResource("Import canceled.")
        case .serviceFailed:
            LocalizedStringResource("The dictionary service stopped before it finished. Try again.")
        }
    }

    public static func note(_ note: EntryNote) -> LocalizedStringResource {
        switch note {
        case .missingVolume(let name):
            LocalizedStringResource("Resource volume “\(name)” is missing: pictures and sounds in it will not be found.")
        case .outsideChosenFolder(let name):
            LocalizedStringResource("“\(name)” points outside the folder you chose, so XDict does not read it.")
        case .sidecarsOmitted(let count):
            LocalizedStringResource("""
                \(count) files beside the dictionary were left out: one dictionary takes at most 64 files.
                """)
        case .volumeUnreadable(let name, let reason):
            LocalizedStringResource("Resource volume “\(name)” could not be read. \(String(localized: refusal(reason)))")
        }
    }

    /// What a speaker icon says (L6): the recording plays, is in a format macOS does not play, or is not there.
    public static func sound(_ sound: SoundDiagnosis) -> LocalizedStringResource {
        switch sound {
        case .playable:
            LocalizedStringResource("Plays the dictionary's own recording.")
        case .unsupported(let format):
            LocalizedStringResource("This recording is in a format macOS does not play (\(format)).")
        case .missing(let path):
            LocalizedStringResource("This recording is not among the dictionary's files (\(path)).")
        }
    }

    public static func notice(_ notice: LibraryNotice) -> LocalizedStringResource {
        switch notice {
        case .finder(.notADictionaryFile(let name)):
            LocalizedStringResource("“\(name)” is not a dictionary file (.mdx or .mdd).")
        case .finder(.noDictionaryIn(let folder)):
            LocalizedStringResource("No dictionary was found in “\(folder)”.")
        case .finder(.volumesWithoutDictionary(let names)):
            LocalizedStringResource("No dictionary (.mdx) was found for “\(names.joined(separator: "”, “"))”.")
        case .finder(.outsideChosenFolder(let name)):
            LocalizedStringResource("“\(name)” points outside the folder you chose, so it was not added.")
        case .finder(.unreadable(let name)):
            LocalizedStringResource("“\(name)” could not be added: it was moved or deleted, or XDict does not have permission to read it.")
        case .alreadyInLibrary(let name):
            LocalizedStringResource("Already in your library, as “\(name)”.")
        case .relinked(let name):
            LocalizedStringResource("Found “\(name)” again.")
        case .locked(let name):
            LocalizedStringResource("\(name) was not added: it is locked to its buyer with a registration code.")
        case .notSaved:
            LocalizedStringResource("Your library could not be saved.")
        }
    }

    /// The one line several notices are gathered into (UI review X7); each is listed, with its reason, behind it.
    public static func noticesHeadline(_ count: Int) -> LocalizedStringResource {
        count == 1 ? LocalizedStringResource("1 file could not be added.")
            : LocalizedStringResource("\(count) files could not be added.")
    }

    /// Why the library itself cannot be used, and that it was left alone.
    public static func unreadable(_ error: LibraryStoreError) -> LocalizedStringResource {
        switch error {
        case .newerVersion:
            LocalizedStringResource("Your library was saved by a newer XDict. Update XDict to use it; it was left as it is.")
        case .damaged, .unavailable:
            LocalizedStringResource("Your library file could not be read, so XDict leaves it as it is and adds nothing to it.")
        }
    }

    /// One line for where a dictionary is.
    public static func phase(_ phase: EntryPhase) -> LocalizedStringResource {
        switch phase {
        case .waiting: LocalizedStringResource("Waiting to import")
        case .importing: LocalizedStringResource("Importing…")
        case .cancelling: LocalizedStringResource("Canceling…")
        case .opening: LocalizedStringResource("Opening…")
        case .ready: LocalizedStringResource("Ready")
        case .cancelled: refusal(.cancelled)
        case .refused(let why), .failed(let why): refusal(why)
        case .missing(let name): refusal(.missingFile(name))
        case .outsideItsFolder(let name):
            LocalizedStringResource("“\(name)” has become a link or has left its folder, so XDict will not read it.")
        }
    }

    // MARK: - Health (WI-12)

    /// One sentence per finding of the health check, saying how many; nothing asks the reader to mend what XDict mends.
    public static func health(_ finding: HealthFinding) -> LocalizedStringResource {
        let n = finding.count
        switch finding.kind {
        case .missingFile:
            return LocalizedStringResource("""
                “\(finding.name ?? "")” is not in this dictionary’s folder, but its entries use it \(n) times, so they may \
                look unstyled or not work. Put the file next to the .mdx to fix this.
                """)
        case .missingSounds:
            return LocalizedStringResource("\(n) pronunciations point to sound files that are not here. Add the dictionary’s .mdd file.")
        case .missingImages:
            return LocalizedStringResource("\(n) pictures are not among the dictionary’s files.")
        case .missingWords:
            return LocalizedStringResource("\(n) cross-references point to words this dictionary does not have.")
        case .codeAsText:
            return LocalizedStringResource("\(n) places show HTML code as text. This is in the dictionary file itself.")
        case .commentMarks:
            return LocalizedStringResource("""
                \(n) places show comment marks such as “-->” as text, or hide text in a broken comment. This is in the \
                dictionary file itself.
                """)
        case .styleAsText:
            return LocalizedStringResource("\(n) entries show style rules as text. This is in the dictionary file itself.")
        case .brokenRedirects:
            return LocalizedStringResource("\(n) entries redirect to an entry that does not exist, or back to themselves.")
        case .doubleEncoded:
            return LocalizedStringResource("\(n) places show garbled characters: their text was encoded twice when the dictionary was made.")
        case .undecodable:
            return LocalizedStringResource("\(n) entries hold bytes that are not text in the dictionary’s encoding.")
        case .emptyEntries:
            return LocalizedStringResource("\(n) entries are empty.")
        case .hugeEntries:
            return LocalizedStringResource("\(n) entries are larger than 1 MB and may be slow to show.")
        case .repeatedEntries:
            return LocalizedStringResource("\(n) entries are stored twice under the same headword.")
        case .oddHeadwords:
            return LocalizedStringResource("\(n) headwords hold extra spaces, invisible characters or HTML code.")
        case .repaired:
            return LocalizedStringResource("XDict cleans up \(n) stray control characters and line breaks when it shows these entries.")
        }
    }

    /// Where the check is: running (how far), done (healthy, or with findings below), or unable to finish.
    public static func healthStatus(_ state: HealthState) -> LocalizedStringResource {
        switch state {
        case .checking(let done, let total):
            let percent = total > 0 ? Int(done * 100 / total) : 0
            return LocalizedStringResource("Checking entries… \(percent)%")
        case .checked(let health) where health.entries == 1:
            return health.findings.allSatisfy({ $0.kind == .repaired })
                ? LocalizedStringResource("Healthy. Checked its 1 entry.") : LocalizedStringResource("Checked its 1 entry.")
        case .checked(let health) where health.findings.allSatisfy({ $0.kind == .repaired }):
            return LocalizedStringResource("Healthy. Checked all \(health.entries) entries.")
        case .checked(let health):
            return LocalizedStringResource("Checked all \(health.entries) entries.")
        case .unavailable:
            return LocalizedStringResource("The check could not finish. It runs again when the dictionary next opens.")
        }
    }

    // MARK: - Reading style (ADR-0010)

    /// Where the report is: being made, made (which rules' version), or not made.
    public static func styleStatus(_ state: StyleState) -> LocalizedStringResource {
        switch state {
        case .reading: LocalizedStringResource("Reading the dictionary’s style…")
        case .read(let style): LocalizedStringResource("XDict reading style, rules version \(style.version).")
        case .unavailable:
            LocalizedStringResource("The style report could not be made. It is asked again when these details next show.")
        }
    }

    /// The base size and where it was read; a selector is the dictionary's own text, quoted as written.
    public static func baseSize(px: Double, from source: BaseSource) -> LocalizedStringResource {
        let size = px.formatted(.number.precision(.fractionLength(0...2)))
        switch source {
        case .page(let selector):
            return LocalizedStringResource("Base size \(size) px, from the dictionary’s page rule “\(selector)”.")
        case .prose(let weight):
            return LocalizedStringResource("Base size \(size) px, the size most of its text rules set (\(weight) votes).")
        case .text(_, let share):
            let percent = Int((share * 100).rounded())
            return LocalizedStringResource("Text size \(size) px: \(percent)% of a sample of its entries are set in it.")
        case .browserDefault:
            return LocalizedStringResource("Base size \(size) px: the dictionary sets no size of its own.")
        }
    }

    /// Why one of the dictionary's fonts is kept.
    public static func fontReason(_ reason: FontReason) -> LocalizedStringResource {
        switch reason {
        case .privateUse: LocalizedStringResource("Kept: it draws icons no other font has.")
        case .pseudoContent: LocalizedStringResource("Kept: it draws the dictionary’s marks and symbols.")
        case .phonetic: LocalizedStringResource("Kept: it draws phonetic symbols.")
        }
    }

    /// What normalizing the sheets changed, one line per kind that changed; one line when nothing did.
    public static func styleChanges(_ c: StyleChanges) -> [LocalizedStringResource] {
        var lines: [LocalizedStringResource] = []
        if c.important > 0 { lines.append(LocalizedStringResource("\(c.important) “!important” marks removed")) }
        if c.page > 0 { lines.append(LocalizedStringResource("\(c.page) page settings dropped")) }
        if c.family > 0 { lines.append(LocalizedStringResource("\(c.family) fonts replaced with XDict’s")) }
        if c.size > 0 { lines.append(LocalizedStringResource("\(c.size) font sizes made relative")) }
        if c.lineHeight > 0 { lines.append(LocalizedStringResource("\(c.lineHeight) line heights made relative")) }
        if c.colour > 0 { lines.append(LocalizedStringResource("\(c.colour) colors set to XDict’s palette")) }
        if c.weight > 0 { lines.append(LocalizedStringResource("\(c.weight) font weights set to XDict’s")) }
        if c.space > 0 { lines.append(LocalizedStringResource("\(c.space) spacings put on XDict’s steps")) }
        if c.dropped > 0 {
            lines.append(LocalizedStringResource("\(c.dropped) backgrounds, borders and other declarations dropped"))
        }
        return lines.isEmpty ? [LocalizedStringResource("Normalizing changed nothing in its style sheets.")] : lines
    }
}
