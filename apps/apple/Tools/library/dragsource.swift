// dragsource: the other end of the library's drag-and-drop check (plan-macos-v1 WI-5; the E2E `library` stage). A
// small window holding one file, which starts a real drag of that file (a file URL on the drag pasteboard, as Finder
// puts one) when the pointer drags in it — `pointer drag` from its centre to the library window's is a person dragging
// a dictionary in from elsewhere. Built into the E2E kit by `Tools/build-lab.sh`; run on the E2E Mac only.
//
//   dragsource <file> <x> <y> <ready-file>   the window's top left at (x, y), global display points from the top
//                                            left; writes "<cx> <cy>" (its centre) to <ready-file> once on screen;
//                                            exits 0 when a drag ends in a drop, 1 when one ends without, 2 when
//                                            nothing happened within 60 s
import AppKit

func die(_ message: String, _ status: Int32) -> Never {
    FileHandle.standardError.write(Data(("dragsource: " + message + "\n").utf8))
    exit(status)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4, let x = Double(arguments[1]), let y = Double(arguments[2]) else {
    die("usage: dragsource <file> <x> <y> <ready-file>", 2)
}
let file = URL(fileURLWithPath: arguments[0])
guard FileManager.default.fileExists(atPath: file.path) else { die("no file at \(file.path)", 2) }

final class Source: NSView, NSDraggingSource {
    let file: URL
    var started = false

    init(file: URL, frame: NSRect) {
        self.file = file
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    // The first click of a window not yet active still starts the drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDragged(with event: NSEvent) {
        guard !started else { return }
        started = true
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 48, height: 48), contents: NSWorkspace.shared.icon(forFile: file.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        print("dragsource: the drag ended with operation \(operation.rawValue)")
        exit(operation.isEmpty ? 1 : 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        bounds.fill()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let size = NSSize(width: 140, height: 100)
let screen = NSScreen.main?.frame ?? .zero
let window = NSWindow(contentRect: NSRect(x: x, y: screen.maxY - y - size.height, width: size.width, height: size.height),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.level = .floating
window.contentView = Source(file: file, frame: NSRect(origin: .zero, size: size))
window.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    let shown = window.frame
    let centre = "\(Int(shown.midX)) \(Int(screen.maxY - shown.midY))\n"
    do {
        try Data(centre.utf8).write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
    } catch {
        die("the ready file could not be written: \(error)", 2)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { die("no drag ended within 60 s", 2) }
app.run()
