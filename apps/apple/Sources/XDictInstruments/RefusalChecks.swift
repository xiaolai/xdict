import Foundation
@_spi(Instruments) import XDictClient
import XDictContract

extension ServiceChecks {
    /// **A dictionary handed by path is refused** — and the contract has no path to hand, so the closest real requests
    /// are sent as the client would never send them (`submitUnchecked`): a package with no handle at all, a pipe, a file
    /// opened for writing, another file's handle under this file's token, and a lookup without its tokens. Each must be
    /// refused before the core is asked, with its own kind; the same package sent properly is answered (the control).
    public func refusals() async -> Findings {
        var findings = Findings()
        let client = makeClient(.contract, nil)
        let observer = FileObserver()
        let dir = fixtures.appending(path: "tiny")
        let mdx = dir.appending(path: "tiny.mdx"), volume = dir.appending(path: "tiny.mdd")
        let file = UUID()
        let spec = PackageSpec(files: [.mdx(id: file)])
        let token = observer.token(file: file, at: mdx)

        func expect(_ name: String, _ outcome: ClientOutcome, _ refusal: Refusal) {
            findings.check(name, outcome == .failure(.wire(.refused(refusal))), "\(outcome)")
        }

        expect("refusal.noHandle", await client.submitUnchecked(.openPackage(spec: spec), files: nil, tokens: [token]).outcome(),
               .missingHandle)
        let pipe = Pipe()
        expect("refusal.pipe", await client.submitUnchecked(.openPackage(spec: spec), files: [pipe.fileHandleForReading],
                                                          tokens: [token]).outcome(), .notARegularReadOnlyFile(file: file))
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()

        let writable = scratch.appending(path: "writable.mdx")
        try? FileManager.default.removeItem(at: writable)
        if (try? FileManager.default.copyItem(at: mdx, to: writable)) != nil, let handle = try? FileHandle(forUpdating: writable) {
            expect("refusal.writable", await client.submitUnchecked(
                .openPackage(spec: spec), files: [handle], tokens: [observer.token(file: file, at: writable)]).outcome(),
                   .notARegularReadOnlyFile(file: file))
            try? handle.close()
        } else {
            findings.check("refusal.writable", false, "a writable copy of tiny.mdx could not be made")
        }

        if let other = try? FileHandle(forReadingFrom: volume) {
            expect("refusal.otherFile", await client.submitUnchecked(.openPackage(spec: spec), files: [other],
                                                                   tokens: [token]).outcome(), .handleIsNotThePathsFile(file: file))
            try? other.close()
        } else {
            findings.check("refusal.otherFile", false, "tiny.mdd could not be opened")
        }

        // The control: the same file sent as a handle with its token is a package the service reads.
        let package = tiny
        switch await ready(package, on: client) {
        case .success(let dict):
            findings.check("refusal.control", true, "tiny opened as \(dict.rawValue) when sent as handles")
            let mdxID = package.files.first?.spec.id ?? UUID()
            expect("refusal.missingToken", await client.submitUnchecked(
                .lookup(query: "run", dicts: [dict], options: Self.firstPage), files: nil, tokens: []).outcome(),
                   .missingToken(file: mdxID))
        case .failure(let why):
            findings.check("refusal.control", false, "tiny sent as handles was not opened: \(why)")
            findings.check("refusal.missingToken", false, "no dictionary was open to ask")
        }
        return findings
    }
}
