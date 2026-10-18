import Foundation
import XDictAppleSource
import XDictBase
import XDictContract
import os

// The dictionary service: the only process that runs the core (ADR-0001 decision 5), sandboxed with no file and no
// network entitlement (`Resources/DictionaryService.entitlements`), answering the frozen contract (`XDictContract`,
// ADR-0009). A crash here ends a process launchd starts again on the next request, never the reader's app; so does the
// idle exit (`IdleExit`). `resume()` on the service listener does not return.
let log = Logger(subsystem: XDictIdentity.dictionaryService, category: "service")

guard let storage = ServiceContext.containerStorage() else {
    log.fault("not running in its own sandbox container; refusing to start")
    exit(1)
}
let check = ClientCheck.ownTeamApp()
switch check {
case .requirement(let requirement):
    log.notice("client requirement: \(requirement, privacy: .public)")
case .refuseAll(let why):
    log.fault("no client requirement could be built, so every connection is refused: \(why, privacy: .public)")
#if DEBUG
case .anyoneForTests:
    break
#endif
}
let idle = IdleExit.production { quietFor in
    log.notice("idle exit: \(quietFor.components.seconds, privacy: .public) s quiet, nothing in flight")
}
// The app-group container the app stages Apple dictionaries in (ADR-0011 decision 4), named by this process's own team.
// Without one (unsigned, or no entitlement) the service still runs, and refuses every conversion as `noContainer`.
let appleImports = SharedContainer.appleImports().map { AppleImportStore(root: $0) }
if appleImports == nil { log.error("no app-group container: Apple dictionary conversions will be refused") }
let context = ServiceContext(dictionaries: Dictionaries(storage: storage), idle: idle, appleImports: appleImports)
let delegate = ServiceListener(context: context, check: check)
let listener = NSXPCListener.service()
listener.delegate = delegate
idle.start()
listener.resume()
