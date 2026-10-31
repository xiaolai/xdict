import Foundation
import XDictContract
import XDictSearch

/// **The words the word-data row says** (plan-word-exploration WI-5): the app's own, in the reader's language, from the
/// kinds the model reports (ADR-0007 decision 10 — the service sends kinds, the shell words them). A refusal names
/// what was refused and, for a version, which version the file declares: the one thing the reader has to act on.
public enum WordDataSentences {
    public static let title = LocalizedStringResource("Word data")
    public static let installed = LocalizedStringResource("Word data is installed.")
    public static let absent = LocalizedStringResource(
        "Rhymes, word families, roots, forms, synonyms and antonyms need the word data, which is not installed yet.")
    public static let choose = LocalizedStringResource("Choose Word Data…")
    public static let remove = LocalizedStringResource("Remove")
    public static let build = LocalizedStringResource("Build Word Data…")
    public static let cancel = LocalizedStringResource("Cancel")

    /// **What the download is doing** (plan-local-word-pack WI-6): the file in hand by name and of how many, and how
    /// far in — the size and the minutes said once, before it starts, so nobody waits for 185 MB unannounced.
    public static func downloading(_ progress: WordDataProgress) -> LocalizedStringResource {
        let done = progress.done.formatted(.byteCount(style: .file))
        let total = progress.total.formatted(.byteCount(style: .file))
        return LocalizedStringResource("""
            Downloading the word data from its own sources: \(progress.name), file \(String(progress.file)) of \
            \(String(progress.files)), \(done) of \(total). This is about 185 MB, and a few minutes of this Mac's \
            time once it is here.
            """, comment: "Word data: the file being downloaded, its byte count so far and of all")
    }

    /// **What the build is doing** (contract 20's progress): the phase the core's own report names, and the bytes of
    /// the sources it has parsed. Before the first parsed byte there is no amount and no phase to claim beyond the
    /// build itself — the row says that rather than leaving a bar at zero — and the last byte parsed is the writing one.
    public static func building(_ progress: WordDataBuild) -> LocalizedStringResource {
        switch progress.phase {
        // **A build is never the download phase**; the kind is shared with the row's download state.
        case .downloading, .preparing:
            return LocalizedStringResource("""
                Building the word data from the downloaded sources. This takes a few minutes and needs no network.
                """, comment: "Word data: a build under way before the core has parsed a source byte")
        case .building:
            let done = progress.done.formatted(.byteCount(style: .file))
            let total = progress.total.formatted(.byteCount(style: .file))
            return LocalizedStringResource("""
                Building the word data: \(done) of \(total) parsed. This needs no network.
                """, comment: "Word data: the build's sources parsed, their bytes so far and of all")
        case .writing:
            return LocalizedStringResource("""
                Building the word data: writing the pack. This needs no network.
                """, comment: "Word data: the build writing the pack, every source parsed")
        }
    }

    /// What is installed, in one line: the schema version, the records it holds and its sources — enough to tell one
    /// release of the pack from another without opening the file.
    public static func summary(_ pack: WordPackInfo) -> LocalizedStringResource {
        LocalizedStringResource("""
            Version \(String(pack.version)) · \(pack.records.formatted(.number.grouping(.automatic))) records · \
            sources: \(pack.sources.joined(separator: ", "))
            """, comment: "Word data: the pack's schema version, its record count and its sources")
    }

    /// Why a chosen file was refused.
    public static func sentence(_ refusal: WordDataRefusal) -> LocalizedStringResource {
        switch refusal {
        case .version(let found):
            LocalizedStringResource("""
                The word data is version \(found), which this XDict cannot read. \
                Install the version that matches this release.
                """)
        case .damaged:
            LocalizedStringResource("That file is damaged or is not XDict word data, so nothing was installed.")
        case .tooLarge:
            LocalizedStringResource("The word data is larger than this XDict holds, so nothing was installed.")
        case .unreadable:
            LocalizedStringResource("That file could not be read, so nothing was installed.")
        case .transport:
            LocalizedStringResource("The dictionary service did not answer, so nothing was installed.")
        case .build(let detail):
            LocalizedStringResource("The word data could not be built: \(detail)")
        }
    }

    /// What went wrong around the pack, with no file judged.
    public static func sentence(_ trouble: WordDataTrouble) -> LocalizedStringResource {
        switch trouble {
        case .noContainer:
            LocalizedStringResource("XDict could not reach the folder it shares with its dictionary service.")
        case .copyFailed:
            LocalizedStringResource("That file could not be copied into place. Try another file.")
        case .removeFailed:
            LocalizedStringResource("The word data could not be removed. Try again.")
        case .noAnswer:
            LocalizedStringResource("The dictionary service did not answer.")
        case .noManifest:
            LocalizedStringResource("This XDict has no word data sources to download, so nothing was built.")
        case .download(let failure):
            sentence(failure)
        }
    }

    /// **Why a download failed, naming the file** (plan-local-word-pack WI-6): the file and both hashes for a mismatch
    /// — the one thing that tells a damaged mirror from a substituted file — and the transport's own words otherwise.
    public static func sentence(_ failure: WordPackDownload.Failure) -> LocalizedStringResource {
        switch failure {
        case .transport(let file, let detail):
            return LocalizedStringResource("The word data's \(file) could not be downloaded: \(detail)")
        case .tooLarge(let file, let limit):
            let size = limit.formatted(.byteCount(style: .file))
            return LocalizedStringResource("""
                The word data's \(file) is larger than the \(size) XDict pins for it, so nothing was installed.
                """, comment: "Word data: a download streamed past the size the manifest pins")
        case .sizeMismatch(let file, let expected, let found):
            return LocalizedStringResource("""
                The word data's \(file) arrived at \(String(found)) bytes instead of \(String(expected)), so nothing \
                was installed.
                """)
        case .hashMismatch(let file, let expected, let found):
            return LocalizedStringResource("""
                The word data's \(file) is not the file it should be: its SHA-256 is \(found), and the one XDict \
                checks for is \(expected). Nothing was installed.
                """)
        }
    }
}
