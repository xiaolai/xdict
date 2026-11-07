import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import XDictAnywhere
import XDictCapture
import XDictLibrary
import XDictTokens

/// **Settings ▸ General ▸ Save Diagnostics…** (owner, 2026-10-29): the log `Diagnostics` kept, under a header a developer
/// needs and a reader cannot be expected to describe — this copy's versions, the Mac, the permissions, the hover settings,
/// how many dictionaries the library holds. The words the reader looked up are in it only if they switched that on.
public enum DiagnosticsExport {
    /// The file's name, with the moment it was written: two reports never collide.
    public static func fileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "XDict Diagnostics \(formatter.string(from: now)).txt"
    }

    /// The whole export: the environment block, a blank line, then the log.
    @MainActor
    public static func text(hover: HoverControl?, library: (any DiagnosticsLibrary)?, now: Date = Date(),
                            diagnostics: Diagnostics = .shared) -> String {
        var lines = [
            String(localized: "XDict diagnostics"),
            "written: \(ISO8601DateFormatter().string(from: now))",
            "app: \(bundle("CFBundleShortVersionString")) (\(bundle("CFBundleVersion")))",
            "bundle: \(Bundle.main.bundleIdentifier ?? "—")",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "launch: \(ProcessInfo.processInfo.arguments.contains("-NSDocumentRevisionsDebugMode") ? "debug" : "reader")",
        ]
        if let library {
            lines.append("dictionaries: \(library.total) (\(library.enabled) enabled)")
        }
        if let hover {
            lines.append("hover: enabled=\(hover.isEnabled) watching=\(hover.isWatching) health=\(hover.captureHealth)"
                         + " settle=\(hover.settle.milliseconds)ms gesture=\(hover.policy.gesture)"
                         + " screenRecording=\(hover.screenRecording)")
            if let notice = hover.notice { lines.append("hover: notice=\(notice.rawValue)") }
        }
        lines.append("diagnostics: includeText=\(diagnostics.includeText)")
        lines.append("")
        return lines.joined(separator: "\n") + "\n" + diagnostics.exportText()
    }

    /// What Save Diagnostics… came to: the file written, the reader's cancellation, or why it failed. **A failure is
    /// never silent** (audit 2026-10-29 finding 7): the reader chose to save, and a refusal has to be answered where they
    /// can try again.
    public enum SaveResult: Equatable {
        case saved(URL)
        case cancelled
        case failed(String)
    }

    /// **What SwiftUI's save panel came to** (L13: `fileExporter` writes the file, not this code): the file shown in
    /// Finder and the export recorded, or the failure kept so the pane can say it.
    @MainActor
    public static func saved(_ result: Result<URL, any Error>, bytes: Int) -> SaveResult {
        switch result {
        case .success(let url):
            // AppKit: SwiftUI has no API that reveals a file in Finder.
            NSWorkspace.shared.activateFileViewerSelecting([url])
            Diagnostics.shared.record("diagnostics.exported", ["bytes": "\(bytes)"])
            return .saved(url)
        case .failure(let error as CocoaError) where error.code == .userCancelled:
            return .cancelled
        case .failure(let error):
            Diagnostics.shared.record("diagnostics.exportFailed", ["reason": String(describing: error)])
            return .failed(error.localizedDescription)
        }
    }

    private static func bundle(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "—"
    }
}

/// What the export says about the library, without the export knowing the library.
@MainActor
public protocol DiagnosticsLibrary {
    var total: Int { get }
    var enabled: Int { get }
}

extension Library: DiagnosticsLibrary {
    public var total: Int { entries.count }
    public var enabled: Int { entries.filter(\.enabled).count }
}

/// **A text file for SwiftUI's save panel** (L13): the diagnostics and the learning export are written by `fileExporter`,
/// as UTF-8, under the type each names.
public struct ExportedText: FileDocument {
    public static let readableContentTypes: [UTType] = [.plainText, .json]

    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = String(decoding: data, as: UTF8.self)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
