// XDict for macOS. Not sandboxed: the reader's grants (the files they import, Accessibility later) are the app's, and
// what reads a dictionary file runs in the sandboxed service it asks (ADR-0001 decision 5).
//
// A development instrument is chosen by its flag before any window exists, and exits when it has answered.
import SwiftUI

let arguments = Array(CommandLine.arguments.dropFirst())
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
// The real app, driven: it runs as the reader's does, over a library of its own.
if arguments.contains(LookupWindowReport.flag) {
    LookupWindowReport.prepare(arguments)
}
XDictApp.main()
