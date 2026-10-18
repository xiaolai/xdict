import Foundation
import XDictAnywhere
import XDictCaptureMac

// XDict's capture lab (plan-capture WI-4): a development instrument, never in XDict.app. See PROVENANCE.md and
// `ModuleBoundaryTests.developmentInstruments`.
let status = await LabMain.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    source: SystemPointerWords(metrics: CaptureTolerances.metrics),
    out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
    err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
exit(status.rawValue)
