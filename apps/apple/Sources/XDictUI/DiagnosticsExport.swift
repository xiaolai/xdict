import AppKit
import Foundation
import XDictAnywhere
import UniformTypeIdentifiers
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
            "XDict diagnostics",
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

    /// Writes `text` where the reader said, and shows it in Finder. Answers the file written, or nil when cancelled.
    @MainActor
    @discardableResult
    public static func save(_ text: String, name: String = fileName()) -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Diagnostics")
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Diagnostics.shared.record("diagnostics.exportFailed", ["reason": String(describing: error)])
            return nil
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        Diagnostics.shared.record("diagnostics.exported", ["bytes": "\(text.utf8.count)"])
        return url
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
