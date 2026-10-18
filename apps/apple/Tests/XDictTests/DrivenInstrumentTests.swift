import Foundation
import Testing
import XDictTestSupport

/// **A driven run starts no hover** (plan-capture WI-3): a key an instrument holds must not open a lookup it did not ask
/// for. Every instrument that prepares the real app rather than exiting — `X.prepare(` in `main.swift` — must have its
/// `X.flag` in the line that sets `LookupAnywhere.instrumented`. Read off the code, since `main.swift` cannot run under a
/// test; a positive control plants an instrument the line forgot.
struct DrivenInstrumentTests {
    @Test func everyDrivenInstrumentTurnsHoverOff() throws {
        let main = Manifest.package.appending(path: "Sources/XDict/main.swift")
        let text = try String(contentsOf: main, encoding: .utf8)
        // The premise: the three driven instruments of today are seen. A scan that finds none holds nothing.
        #expect(Self.prepared(text).count >= 3, "the scan read no driven instrument: \(Self.prepared(text))")
        #expect(Self.forgotten(text) == [])
    }

    /// **The control**: an instrument prepared but missing from the line is named; one present is not.
    @Test func aDrivenInstrumentTheLineForgotIsNamed() {
        let planted = """
            if arguments.contains(AReport.flag) {
                AReport.prepare(arguments)
            }
            if arguments.contains(BReport.flag) {
                BReport.prepare(arguments)
            }
            LookupAnywhere.instrumented = [AReport.flag].contains(where: arguments.contains)
            """
        #expect(Self.forgotten(planted) == ["BReport"])
        #expect(Self.forgotten("AReport.prepare(arguments)\n") == ["AReport"], "a missing line hid the instrument")
    }

    static func prepared(_ text: String) -> [String] {
        SourceScan.codeOnly(text).matches(of: /\b([A-Z][A-Za-z0-9]*)\.prepare\(/).map { String($0.output.1) }
    }

    static func forgotten(_ text: String) -> [String] {
        let code = SourceScan.codeOnly(text)
        let line = code.split(separator: "\n").first { $0.contains("LookupAnywhere.instrumented =") } ?? ""
        return prepared(text).filter { !line.contains("\($0).flag") }
    }
}
