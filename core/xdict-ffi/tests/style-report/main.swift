// The style-report parity case through the Swift binding (style-report-parity.sh, on demand only).
// Usage: style-report <case dir>. Prints the binding's `readingStyle` of the case as JSON, in the core's serde shape.

import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
func at(_ name: String) -> Location { .path(path: dir.appendingPathComponent(name).path) }

let core = try Core(config: Config(dataDir: nil, cacheDir: nil, clientProtocol: protocolVersion(), entropy: Data()))
let package = Package(mdx: at("case.mdx"), mdd: [at("case.mdd")], sidecars: [at("case.css")])
_ = try core.import(package: package, progress: nil)
guard case .ready(let dict, _, _) = try core.open(package: package) else { fatalError("the case did not open") }
let s = try core.readingStyle(dict: dict)

let baseFrom: Any = switch s.baseFrom {
case .page(let selector): ["page": ["selector": selector]]
case .prose(let weight): ["prose": ["weight": weight]]
case .text(let chars, let share): ["text": ["chars": chars, "share": share]]
case .browserDefault: "browserDefault"
}
func reason(_ r: FontReason) -> String {
    switch r {
    case .privateUse: "privateUse"
    case .pseudoContent: "pseudoContent"
    case .phonetic: "phonetic"
    }
}
func skipped(_ r: SkipReason) -> Any {
    switch r {
    case .tooMany(let limit): ["tooMany": ["limit": limit]]
    case .tooLarge(let limit, let detail): ["tooLarge": ["limit": limit, "detail": detail]]
    case .notFound: "notFound"
    case .unreadable(let detail): ["unreadable": ["detail": detail]]
    }
}
let c = s.changes
let json: [String: Any] = [
    "version": s.version, "basePx": s.basePx, "baseFrom": baseFrom,
    "fonts": s.fonts.map { ["family": $0.family, "reason": reason($0.reason), "selector": $0.selector] },
    "sheets": s.sheets, "skipped": s.skipped.map { ["path": $0.path, "reason": skipped($0.reason)] },
    "changes": ["important": c.important, "page": c.page, "family": c.family, "size": c.size, "lineHeight": c.lineHeight,
                "colour": c.colour, "weight": c.weight, "space": c.space, "dropped": c.dropped],
]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
