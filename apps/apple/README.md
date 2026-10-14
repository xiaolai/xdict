# apple

macOS and iOS, in Swift and SwiftUI, sharing one Swift package. macOS adds AppKit and runs the core in an
XPC service, so dictionary files are parsed outside the app. It also holds the Safari web extension's
wrapper, built from `apps/extension/`, and the native-messaging host the other browsers' extension calls
(ADR-0008). The reference platform: built first. Not
started.
