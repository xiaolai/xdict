import Foundation

// The NSXPC surface: two `@objc` protocols, one each way on the app's single connection to the service, and the
// interfaces both sides build from here so they cannot disagree. **Nothing here is actor-isolated**, and every reply
// block is `@Sendable`: NSXPC calls back on its own queues, and a closure that inherited `@MainActor` isolation trapped
// in `dispatch_assert_queue` on the first transport error (spike 1). Build proxies, error handlers and reply blocks in
// nonisolated code.

/// **What the service exports.** Every request is an envelope (`Request`, JSON); every reply is the envelope of a
/// `Response` and, for an answer that carries one, its payload (`Answer.carriesPayload`): an entry's HTML as UTF-8, or a
/// found resource's bytes. The payload is never inside the JSON.
@objc(XDDictionaryService)
public protocol DictionaryServiceXPC {
    /// A request whose operation carries no package.
    func call(_ request: Data, reply: @escaping @Sendable (Data, Data?) -> Void)
    /// A request whose operation carries a package (`importPackage`, `openPackage`): one handle per file, in the order
    /// of the package's files. Never a descriptor number, never a path.
    func callWithFiles(_ request: Data, files: [FileHandle], reply: @escaping @Sendable (Data, Data?) -> Void)
}

/// **What the app exports** on the same connection, for the service to call unasked: `ServiceEvent`s as JSON.
/// One-way: NSXPC keeps their order on the connection, and nothing waits for them.
@objc(XDServiceEvents)
public protocol ServiceEventsXPC {
    func event(_ data: Data)
}

/// The interfaces, built the same way on both sides: the app sets `dictionaryService()` as its connection's remote
/// interface and `serviceEvents()` as its exported one; the service the reverse.
public enum XPCInterfaces {
    /// The selector whose `files` argument carries handles.
    public static var callWithFiles: Selector { #selector(DictionaryServiceXPC.callWithFiles(_:files:reply:)) }
    /// `files`, counted from 0 as NSXPC counts arguments.
    public static let filesArgument = 1

    /// The service's interface, admitting `[FileHandle]` for `files`. **Without the class list NSXPC refuses the message
    /// and interrupts the connection** (spike 1's control, `NSCocoaErrorDomain 4097`); with it, the service sees the
    /// inodes the app opened.
    public static func dictionaryService() -> NSXPCInterface {
        let interface = NSXPCInterface(with: DictionaryServiceXPC.self)
        // `NSSet` bridges to `Set<AnyHashable>` whatever its elements, so this cast cannot fail; the API takes only
        // that type, and a class object is not `Hashable` in Swift, so the set cannot be built without the bridge.
        // swiftlint:disable:next force_cast
        let classes = NSSet(array: [NSArray.self, FileHandle.self]) as! Set<AnyHashable>
        interface.setClasses(classes, for: callWithFiles, argumentIndex: filesArgument, ofReply: false)
        return interface
    }

    /// The app's events interface: `Data` only, which NSXPC admits by default.
    public static func serviceEvents() -> NSXPCInterface {
        NSXPCInterface(with: ServiceEventsXPC.self)
    }
}
