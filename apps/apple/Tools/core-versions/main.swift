// The core's versions as JSON, read through the UniFFI binding and the static library the bundle links:
// `Tools/build-core.sh` compiles this beside the generated `xdict.swift` and writes its output to
// `Generated/core-versions.json`. The keys are those of `CoreVersions` in XDictBase, which the handshake answers in.
import Foundation

let answer = versions()
let fields: [String: Any] = [
    "protocol": answer.protocol,
    "core": answer.core,
    "indexFormat": answer.indexFormat,
    "normalization": answer.normalization,
]
let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
