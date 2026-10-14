import Foundation
import XDictContract

/// **What a dictionary's recording is, for the reader** (L6: missing audio and unsupported audio told apart, so that a
/// dead speaker icon has an explanation). From the service's answer alone: `missing` is missing; a found recording is
/// playable when macOS decodes its format with no code of XDict's (`platform-architecture.md` §4a: mp3, WAV and Ogg
/// Vorbis measured, and the system's own formats), and otherwise unsupported, named by its extension — Speex above
/// all, which XDict never decodes. Playing it is WI-7's.
public enum SoundDiagnosis: Hashable, Sendable {
    case playable
    case unsupported(format: String)
    case missing(path: String)

    /// The MIME types the core names that macOS plays (`core.rs` `mime`).
    static let playableTypes: Set<String> = ["audio/mpeg", "audio/wav", "audio/ogg"]
    /// Extensions macOS plays, for files the core names `application/octet-stream`.
    static let playableExtensions: Set<String> = ["mp3", "wav", "ogg", "oga", "m4a", "aac", "mp4", "aif", "aiff", "aifc",
                                                  "caf", "flac"]

    public static func of(_ resource: Resource) -> SoundDiagnosis {
        switch resource {
        case .missing(let path):
            return .missing(path: path)
        case .found(let path, let mime):
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let format = name.contains(".") ? (name.split(separator: ".").last.map(String.init) ?? "").lowercased() : ""
            return playableTypes.contains(mime) || playableExtensions.contains(format) ? .playable
                : .unsupported(format: format)
        }
    }
}
