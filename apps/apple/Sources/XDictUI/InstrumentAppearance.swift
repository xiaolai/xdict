import AppKit

/// **`--appearance dark|light`: the UI tour's own appearance for XDict** (WI-13 fix round, 2026-10-17), so its captures
/// cover dark without changing the Mac's. An instrument's argument alone: honoured only beside `--lookup-window`, and a
/// reader's launch that carries it is refused, so it can never become a hidden way to theme the reader's app.
public enum InstrumentAppearance: Equatable, Sendable {
    case dark, light

    public static let flag = "--appearance"
    /// The instrument it belongs to (`LookupWindowReport.flag`).
    public static let instrument = "--lookup-window"

    public enum Refusal: Error, Equatable {
        case notAnInstrument
        case unknown(String)
    }

    public static func parse(_ arguments: [String]) -> Result<Self?, Refusal> {
        guard let at = arguments.firstIndex(of: flag) else { return .success(nil) }
        guard arguments.contains(instrument) else { return .failure(.notAnInstrument) }
        let value = arguments.indices.contains(at + 1) ? arguments[at + 1] : ""
        switch value {
        case "dark": return .success(.dark)
        case "light": return .success(.light)
        default: return .failure(.unknown(value))
        }
    }

    public var appearance: NSAppearance? {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
}
