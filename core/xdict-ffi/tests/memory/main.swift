// ADR-0007 refutation 24 through the Swift binding: the peak resident memory of one step on the dictionary
// memory-fixture writes. Usage: memory <fixture dir> <import|entry|refused|resource>. Prints the peak before and
// after. `entry` shows the body in a 128 MiB view; `refused` in a 64 MiB one, which the rewritten body exceeds.

import Foundation

func peakMiB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576 // bytes on macOS
}

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: memory <fixture dir> <import|entry|refused|resource>"); exit(2) }
let dir = URL(fileURLWithPath: args[1])
let step = args[2]
let core = try Core(config: Config(dataDir: nil, cacheDir: nil, clientProtocol: protocolVersion(), entropy: Data()))
let package = Package(mdx: .path(path: dir.appendingPathComponent("big.mdx").path),
                      mdd: [.path(path: dir.appendingPathComponent("big.mdd").path)], sidecars: [])
let imported = try core.import(package: package, progress: nil)
guard case let .ready(dict, _, _) = try core.open(package: package) else { fatalError("not open") }
let view = View(baseUrl: "xdict://d/", maxBodyBytes: 128 << 20)
let big = EntryRef(edition: imported.edition, key: "big", occurrence: 0)
let before = peakMiB()
var size = 0
switch step {
case "import": break
case "entry":
    size = try core.entry(dict: dict, entry: big, view: view).html.utf8.count
case "refused":
    do {
        _ = try core.entry(dict: dict, entry: big, view: View(baseUrl: "xdict://d/", maxBodyBytes: 64 << 20))
        print("not refused"); exit(1)
    } catch CoreError.TooLarge {}
case "resource":
    guard case let .found(_, _, bytes) = try core.resource(dict: dict, path: "big.css", view: view) else { fatalError("missing") }
    size = bytes.count
default: print("no step \(step)"); exit(2)
}
print(String(format: "swift %@: peak %.0f MiB before, %.0f MiB after; result %.1f MiB", step, before, peakMiB(), Double(size) / 1_048_576))
