import Foundation
import XDictContract

/// **What the service learns of each received descriptor before admission** (Codex objection 7): its identity by
/// `fstat`, compared with the file's token (`Request.refusal`), and whether it is a regular file opened read-only. A
/// dictionary file arrives only as that: a pipe, a socket or a directory is no file the reader chose, and a writable
/// descriptor would give the service a way to change one. Nothing here reads the file.
enum HandleInspection {
    static func facts(of descriptor: Int32) -> HandleFacts {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return HandleFacts(identity: nil, isRegularReadOnly: false) }
        let flags = fcntl(descriptor, F_GETFL)
        let regular = (info.st_mode & S_IFMT) == S_IFREG
        let readOnly = flags >= 0 && (flags & O_ACCMODE) == O_RDONLY
        return HandleFacts(identity: FileIdentity(stat: info), isRegularReadOnly: regular && readOnly)
    }
}
