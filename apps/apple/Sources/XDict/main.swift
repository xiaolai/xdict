// XDict for macOS. Not sandboxed: the reader's grants (the files they import, Accessibility later) are the app's, and
// what reads a dictionary file runs in the sandboxed service it asks (ADR-0001 decision 5).
//
// A development instrument is chosen by its flag before any window exists, and exits when it has answered.
import SwiftUI
import XDictUI

let arguments = Array(CommandLine.arguments.dropFirst())
// `--appearance` belongs to the UI tour's instrument: a reader's launch that carries it is refused, not themed.
if case .failure(let refusal) = InstrumentAppearance.parse(arguments) {
    FileHandle.standardError.write(Data("XDict: --appearance is refused (\(refusal)); it is \(InstrumentAppearance.instrument)'s alone, as dark or light\n".utf8))
    exit(2)
}
if arguments.contains(HandshakeReport.flag) {
    HandshakeReport.run()
}
if arguments.contains(ServiceReport.flag) {
    ServiceReport.run(arguments)
}
if arguments.contains(ConnectReport.flag) {
    ConnectReport.run()
}
if arguments.contains(LibraryReport.flag) {
    LibraryReport.run(arguments)
}
if arguments.contains(LibraryCorpusReport.flag) {
    LibraryCorpusReport.run(arguments)
}
if arguments.contains(LibraryDropReport.flag) {
    LibraryDropReport.run(arguments)
}
if arguments.contains(AppHostileReport.flag) {
    AppHostileReport.run(arguments)
}
if arguments.contains(AppCorpusReport.flag) {
    AppCorpusReport.run(arguments)
}
if arguments.contains(SoundReport.flag) {
    SoundReport.run(arguments)
}
if arguments.contains(SetupReport.flag) {
    SetupReport.run(arguments)
}
// The real app, driven: it runs as the reader's does, over a library of its own.
if arguments.contains(LookupWindowReport.flag) {
    LookupWindowReport.prepare(arguments)
}
if arguments.contains(AnywhereReport.flag) {
    AnywhereReport.prepare(arguments)
}
if arguments.contains(MeasureReport.flag) {
    MeasureReport.prepare(arguments)
}
// A driven run starts no hover (plan-capture WI-3): a key the instrument holds must not open a lookup it did not ask for.
LookupAnywhere.instrumented = [LookupWindowReport.flag, AnywhereReport.flag, MeasureReport.flag].contains(where: arguments.contains)
XDictApp.main()
