// XDict for macOS. Not sandboxed: the reader's grants (the files they import, Accessibility later) are the app's, and
// what reads a dictionary file runs in the sandboxed service it asks (ADR-0001 decision 5).
//
// A development instrument is chosen by its flag before any window exists, and exits when it has answered.
import SwiftUI

if CommandLine.arguments.dropFirst().contains(HandshakeReport.flag) {
    HandshakeReport.run()
}
XDictApp.main()
