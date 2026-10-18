import Foundation
@testable import XDictAppleImport

// **A strict MDX/MDD 2.0 reader, for the tests only** (ADR-0011 decision 3: the spike's reader is not shipped; the
// core's reader checks every output in production). It reads what `writeMDict` writes, checking every count, size and
// checksum, so a test can compare records in order and exactly.

/// Reads an MDict 2.0 file written by `writeMDict`, checking every count, size and checksum, and
/// calls `visit(key bytes, record bytes)` in file order. MDX records have their terminator removed.
public func readMDict(at url: URL, isMDD: Bool, visit: (Int, [UInt8], [UInt8]) throws -> Void) throws {
    let raw = [UInt8](try Data(contentsOf: url))
    var pos = 0
    func take(_ n: Int, _ what: String) throws -> ArraySlice<UInt8> {
        guard n >= 0, n <= raw.count - pos else { throw ReadError("\(url.lastPathComponent): truncated in \(what)") }
        defer { pos += n }
        return raw[pos..<(pos + n)]
    }
    func beInt<S: Sequence>(_ s: S) -> Int where S.Element == UInt8 { s.reduce(0) { ($0 << 8) | Int($1) } }
    func inflate(_ s: ArraySlice<UInt8>, expected: Int, _ what: String) throws -> [UInt8] {
        let b = Array(s)
        guard b.count >= 8 else { throw ReadError("\(what): short block") }
        let sum = UInt32(beInt(b[4..<8]))
        let data: [UInt8]
        switch b[0] {
        case 0: data = Array(b[8...])
        case 2: data = try b.withUnsafeBufferPointer { try zlibInflate($0, from: 8, to: b.count, expected: expected, budget: nil, corrupt: .recordKey(what)) }
        default: throw ReadError("\(what): unsupported block type \(b[0])")
        }
        guard data.count == expected, adler32(data) == sum else { throw ReadError("\(what): size or checksum mismatch") }
        return data
    }

    let headerLen = beInt(try take(4, "header length"))
    let headerBytes = Array(try take(headerLen, "header"))
    let headerSum = try take(4, "header checksum").reversed().reduce(0) { ($0 << 8) | Int($1) }
    guard UInt32(headerSum) == adler32(headerBytes) else { throw ReadError("header checksum mismatch") }

    let head = Array(try take(40, "key section"))
    guard UInt32(beInt(try take(4, "key section checksum"))) == adler32(head) else { throw ReadError("key section checksum mismatch") }
    let nblocks = beInt(head[0..<8]), nentries = beInt(head[8..<16])
    let indexRaw = beInt(head[16..<24]), indexComp = beInt(head[24..<32]), blocksLen = beInt(head[32..<40])
    // 64-bit fields are read into Int; a value with the top bit set is a corrupt file, not a count
    guard [nblocks, nentries, indexRaw, indexComp, blocksLen].allSatisfy({ $0 >= 0 }) else {
        throw ReadError("key section holds an impossible count or size")
    }
    let index = try inflate(try take(indexComp, "key index"), expected: indexRaw, "key index")
    let unit = isMDD ? 2 : 1
    var sizes: [(count: Int, comp: Int, raw: Int)] = []
    var p = 0
    for _ in 0..<nblocks {
        guard p + 10 <= index.count else { throw ReadError("key index truncated") }
        let count = beInt(index[p..<(p + 8)])
        let firstLen = beInt(index[(p + 8)..<(p + 10)])
        p += 10 + (firstLen + 1) * unit
        guard p + 2 <= index.count else { throw ReadError("key index truncated") }
        let lastLen = beInt(index[p..<(p + 2)])
        p += 2 + (lastLen + 1) * unit
        guard p + 16 <= index.count else { throw ReadError("key index truncated") }
        let comp = beInt(index[p..<(p + 8)]), rawLen = beInt(index[(p + 8)..<(p + 16)])
        guard count >= 0, comp >= 0, rawLen >= 0 else { throw ReadError("key index holds an impossible count or size") }
        sizes.append((count, comp, rawLen))
        p += 16
    }
    guard p == index.count, sizes.reduce(0, { $0 &+ $1.comp }) == blocksLen else { throw ReadError("key index disagrees with key blocks") }
    var keys: [[UInt8]] = []
    var offsets: [Int] = []
    for s in sizes {
        let data = try inflate(try take(s.comp, "key block"), expected: s.raw, "key block")
        var q = 0
        for _ in 0..<s.count {
            guard q + 8 <= data.count else { throw ReadError("key block truncated") }
            offsets.append(beInt(data[q..<(q + 8)]))
            q += 8
            var e = q
            while true {
                guard e + unit <= data.count else { throw ReadError("unterminated key") }
                if data[e..<(e + unit)].allSatisfy({ $0 == 0 }), (e - q) % unit == 0 { break }
                e += unit == 1 ? 1 : 2
            }
            keys.append(Array(data[q..<e]))
            q = e + unit
        }
        guard q == data.count else { throw ReadError("key block has stray bytes") }
    }
    guard keys.count == nentries else { throw ReadError("\(keys.count) keys, header says \(nentries)") }

    let rhead = Array(try take(32, "record section"))
    let rblocks = beInt(rhead[0..<8]), rentries = beInt(rhead[8..<16]), rindexLen = beInt(rhead[16..<24]), rblocksLen = beInt(rhead[24..<32])
    guard rblocks >= 0, rindexLen >= 0, rblocksLen >= 0, rindexLen % 16 == 0, rindexLen / 16 == rblocks, rentries == nentries else { throw ReadError("record section counts disagree") }
    let rindex = Array(try take(rindexLen, "record index"))
    var rsizes: [(comp: Int, raw: Int)] = []
    for b in 0..<rblocks {
        let comp = beInt(rindex[(b * 16)..<(b * 16 + 8)]), rawLen = beInt(rindex[(b * 16 + 8)..<(b * 16 + 16)])
        guard comp >= 0, rawLen >= 0 else { throw ReadError("record index holds an impossible size") }
        rsizes.append((comp, rawLen))
    }
    guard rsizes.reduce(0, { $0 &+ $1.comp }) == rblocksLen, rblocksLen == raw.count - pos else {
        throw ReadError("record blocks disagree with the file size")
    }
    let total = rsizes.reduce(0) { $0 &+ $1.raw }
    var stream: [UInt8] = []
    var base = 0
    var nextBlock = 0
    for (i, key) in keys.enumerated() {
        let start = offsets[i]
        let end = i + 1 < keys.count ? offsets[i + 1] : total
        guard start >= base, start <= end, end <= total else { throw ReadError("record offsets are inconsistent") }
        while base + stream.count < end {
            guard nextBlock < rsizes.count else { throw ReadError("record runs past the last block") }
            let s = rsizes[nextBlock]
            nextBlock += 1
            stream += try inflate(try take(s.comp, "record block"), expected: s.raw, "record block")
        }
        var value = Array(stream[(start - base)..<(end - base)])
        if !isMDD {
            guard value.suffix(3).elementsEqual([0x0d, 0x0a, 0x00]) else { throw ReadError("record without terminator") }
            value.removeLast(3)
        }
        try visit(i, key, value)
        if start - base > 1 << 20 {
            stream.removeFirst(start - base)
            base = start
        }
    }
}

/// Why the test-only reader refused a file: for a test's failure message only.
struct ReadError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
