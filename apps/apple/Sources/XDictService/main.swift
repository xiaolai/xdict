import Foundation

// The dictionary service: the only process that runs the core (ADR-0001 decision 5), sandboxed with no file and no
// network entitlement (`Resources/DictionaryService.entitlements`). A crash here ends a process launchd starts again on
// the next request, never the reader's app. `resume()` on the service listener does not return.
let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
