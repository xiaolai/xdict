import zlib

// The system's libz, through its documented interface: strict about a stream's end and its consumption, which the
// Compression framework does not report.

/// Adler-32 as used by zlib and by MDict block headers.
func adler32(_ p: UnsafeBufferPointer<UInt8>) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    var i = 0
    let n = p.count
    while i < n {
        let end = min(i + 5552, n)
        while i < end {
            a &+= UInt32(p[i])
            b &+= a
            i += 1
        }
        a %= 65521
        b %= 65521
    }
    return (b << 16) | a
}

func adler32(_ a: [UInt8]) -> UInt32 { a.withUnsafeBufferPointer { adler32($0) } }

/// **The largest block inflated at once**: 256 MiB. Apple's sections and MDict's blocks are far smaller (tens of KiB);
/// this is the bound a lying size field meets before memory does.
let maxInflatedBlock = 1 << 28

/// **Deflate cannot expand its input more than about 1032:1** (each 258-byte match costs at least two bits), so a block
/// claiming more is lying, and is refused before its buffer is allocated.
let maxDeflateRatio = 1032

/// Inflates the zlib stream `buf[from..<to]` to exactly `expected` bytes, charging `budget` first. The whole stream must
/// be consumed and its own Adler-32 must match (libz verifies both and rejects invalid headers). A damaged stream is
/// `corrupt`, a lying size a bound.
func zlibInflate(_ buf: UnsafeBufferPointer<UInt8>, from: Int, to: Int, expected: Int, budget: DecompressionBudget?,
                 corrupt: Corruption) throws -> [UInt8] {
    guard from >= 0, to <= buf.count, to - from >= 0, let base = buf.baseAddress else {
        throw AppleImportError.corrupt(corrupt)
    }
    let n = to - from
    guard n <= Int(UInt32.max), expected >= 0, expected <= maxInflatedBlock, expected <= n * maxDeflateRatio + 64 else {
        throw AppleImportError.boundExceeded(.inflatedBlock(claimed: expected))
    }
    try budget?.charge(expected)
    var out = [UInt8](repeating: 0, count: expected + 1)  // +1 so overlong output is detectable
    var strm = z_stream()
    guard inflateInit_(&strm, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw AppleImportError.corrupt(corrupt)
    }
    defer { inflateEnd(&strm) }
    var status: Int32 = Z_OK
    var inflated = 0
    var consumed = 0
    out.withUnsafeMutableBufferPointer { dst in
        strm.next_in = UnsafeMutablePointer(mutating: base + from)
        strm.avail_in = UInt32(n)
        strm.next_out = dst.baseAddress
        strm.avail_out = UInt32(dst.count)
        status = inflate(&strm, Z_FINISH)
        inflated = Int(strm.total_out)
        consumed = n - Int(strm.avail_in)
    }
    guard status == Z_STREAM_END, inflated == expected, consumed == n else { throw AppleImportError.corrupt(corrupt) }
    out.removeLast()
    return out
}

/// A complete zlib stream for `data` (may be empty).
func zlibCompress(_ data: [UInt8]) throws -> [UInt8] {
    guard data.count <= 1 << 30 else { throw AppleImportError.boundExceeded(.output(limit: 1 << 30)) }
    var strm = z_stream()
    guard deflateInit_(&strm, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw AppleImportError.unwritable(file: "zlib", code: 0)
    }
    defer { deflateEnd(&strm) }
    var out = [UInt8](repeating: 0, count: Int(deflateBound(&strm, UInt(data.count))))
    var status: Int32 = Z_OK
    var produced = 0
    out.withUnsafeMutableBufferPointer { dst in
        data.withUnsafeBufferPointer { src in
            strm.next_in = src.baseAddress.map { UnsafeMutablePointer(mutating: $0) }
            strm.avail_in = UInt32(src.count)
            strm.next_out = dst.baseAddress
            strm.avail_out = UInt32(dst.count)
            status = deflate(&strm, Z_FINISH)
            produced = Int(strm.total_out)
        }
    }
    guard status == Z_STREAM_END else { throw AppleImportError.unwritable(file: "zlib", code: Int(status)) }
    out.removeSubrange(produced...)
    return out
}
