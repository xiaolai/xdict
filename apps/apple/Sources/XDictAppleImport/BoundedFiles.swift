import Foundation

/// **Every file the converter reads, read through here, bounded** (hardening of ADR-0011 decision 4): opened without
/// following a symbolic link, and refused once it passes `limit` bytes, before more than `limit + 1` is held. `name` is
/// what a refusal calls the file (relative to the snapshot, never a path of this Mac).
func readBounded(_ url: URL, limit: Int, name: String) throws -> [UInt8] {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
        if errno == ELOOP { throw AppleImportError.symbolicLink(name) }
        throw AppleImportError.unreadable(file: name, code: Int(errno))
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    let data: Data
    do {
        data = try handle.read(upToCount: limit + 1) ?? Data()
    } catch {
        throw AppleImportError.unreadable(file: name, code: (error as NSError).code)
    }
    guard data.count <= limit else { throw AppleImportError.boundExceeded(.sourceFile(name: name, limit: limit)) }
    return [UInt8](data)
}

/// A new file for writing, refused if anything is already at `url` (converted files are never overwritten, ADR-0011
/// decision 9), every write charged to `meter`.
final class OutputFile {
    private let handle: FileHandle
    private let name: String
    private let meter: OutputMeter

    init(_ url: URL, meter: OutputMeter) throws {
        name = url.lastPathComponent
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            if errno == EEXIST { throw AppleImportError.outputExists(file: url.lastPathComponent) }
            throw AppleImportError.unwritable(file: url.lastPathComponent, code: Int(errno))
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.meter = meter
    }

    func put(_ bytes: [UInt8]) throws {
        try meter.charge(bytes.count)
        do { try handle.write(contentsOf: Data(bytes)) } catch {
            throw AppleImportError.unwritable(file: name, code: (error as NSError).code)
        }
    }

    func finish() throws {
        do { try handle.synchronize() } catch { throw AppleImportError.unwritable(file: name, code: (error as NSError).code) }
    }
}
