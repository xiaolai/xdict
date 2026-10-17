import Foundation

/// **The real string catalog, compiled as the bundle compiles it** (`xcstringstool compile`, Tools/build-bundle.sh), so a
/// test can read a sentence in a language as the reader would: plural forms chosen, numbers formatted for that
/// language. A test process has no XDict.app around it, so `Bundle.main` holds no tables and every key would come back
/// as its English source, "1 files" included. Compiled once per process; the directory lives as long as the process.
public enum CompiledCatalog {
    public static let catalogPath = "Strings/Localizable.xcstrings"

    public enum Failure: Error, CustomStringConvertible {
        case compile(String)
        case noLanguage(String)

        public var description: String {
            switch self {
            case .compile(let said): "xcstringstool could not compile the catalog: \(said)"
            case .noLanguage(let language): "the compiled catalog has no \(language).lproj"
            }
        }
    }

    private static let compiled: Result<TemporaryDirectory, any Error> = Result {
        let scratch = try TemporaryDirectory(named: "xdict-compiled-catalog")
        let (status, _, said) = try Manifest.run("/usr/bin/xcrun", [
            "xcstringstool", "compile", Manifest.package.appending(path: catalogPath).path,
            "--output-directory", scratch.url.path,
        ])
        guard status == 0 else { throw Failure.compile(said) }
        return scratch
    }

    /// Where the tables are: `<language>.lproj/Localizable.strings` and `.stringsdict`.
    public static func directory() throws -> URL {
        try compiled.get().url
    }

    /// One language's tables as a bundle.
    public static func bundle(_ language: String) throws -> Bundle {
        guard let bundle = Bundle(url: try directory().appending(path: "\(language).lproj")) else {
            throw Failure.noLanguage(language)
        }
        return bundle
    }

    /// `resource` as the reader of `language` reads it, numbers formatted for `locale` (by default the language's own).
    public static func text(_ resource: LocalizedStringResource, in language: String, locale: Locale? = nil) throws
        -> String {
        String(localized: resource.defaultValue, table: resource.table, bundle: try bundle(language),
               locale: locale ?? Locale(identifier: language))
    }
}
