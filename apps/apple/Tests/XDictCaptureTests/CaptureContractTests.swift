import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import XDictCapture

/// **The capture contract's value fixtures** (`conformance/capture/CONTRACT.md` §8; plan-capture-contract WI-3): every
/// case in `conformance/capture/vectors.jsonl` through the **production** constructor, the complete output compared
/// ordinal UTF-16. The adapter decodes and encodes the fixture grammar and nothing more — it never validates, rounds,
/// or substitutes a value, because a case the adapter repairs certifies nothing (Codex objection 6).
struct CaptureContractTests {
    static let vectors = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "conformance/capture/vectors.jsonl")

    /// A fixture the harness could not use — never an expected refusal.
    struct Harness: Error, CustomStringConvertible { let description: String }

    @Test func theValueFixtures() throws {
        let data = try Data(contentsOf: Self.vectors)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let (ids, failures) = try run(data)
        print("capture-contract cases: \(ids.sorted().joined(separator: " "))")
        print("capture-contract: \(ids.count) value cases, suite sha256:\(digest)")
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// **A fixture the adapter cannot use is a harness failure** (`CONTRACT.md` §8; `README.md` step 4): an unsupported
    /// grammar or major, an unknown operation, a duplicate id, a missing field or a malformed line stops the run — it is
    /// never counted as an expected refusal. Each record below is otherwise well formed.
    @Test func aFixtureTheAdapterCannotUseIsAHarnessFailure() {
        let runner = CaptureContractTests()
        let record = #"{"format":1,"contract":1,"id":"a","op":"make","input":{"term":"","trigger":"selection","#
            + #""acquisition":"textRange","confidence":1,"source":null,"pointer":null,"box":{"kind":"absent"},"#
            + #""context":{"kind":"unavailable","reason":"notCaptured"}},"expect":{"status":"invalid","code":"term"}}"#
        for broken in [
            record + "\n" + record + "\n",                                     // a duplicate id
            record.replacingOccurrences(of: #""op":"make""#, with: #""op":"frobnicate""#),
            record.replacingOccurrences(of: #""format":1"#, with: #""format":2"#),
            record.replacingOccurrences(of: #""contract":1"#, with: #""contract":2"#),
            #"{"format":1,"contract":1,"id":"a","op":"make","input":{}}"#,     // no expect
            #"{"#,                                                             // not JSON
        ] {
            #expect(throws: Harness.self, "the harness accepted: \(broken)") { try runner.run(Data(broken.utf8)) }
        }
        #expect(throws: Never.self) { try runner.run(Data(record.utf8)) }
    }

    /// The suite in `data`: its ids and its per-case problems. Throws `Harness` for a fixture the adapter cannot use —
    /// never for a case that legitimately refuses.
    func run(_ data: Data) throws -> (ids: [String], failures: [String]) {
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var ids = Set<String>()
        var failures: [String] = []
        for (index, line) in lines.enumerated() {
            let where_ = "line \(index + 1)"
            let parsed: Any
            do { parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
            catch { throw Harness(description: "\(where_): not JSON (\(error.localizedDescription))") }
            guard let object = parsed as? [String: Any] else {
                throw Harness(description: "\(where_): not a JSON object")
            }
            guard object["format"] as? Int == 1 else {
                throw Harness(description: "\(where_): unsupported fixture grammar \(String(describing: object["format"]))")
            }
            guard object["contract"] as? Int == 1 else {
                throw Harness(description: "\(where_): unsupported contract major \(String(describing: object["contract"]))")
            }
            guard object["op"] as? String == "make" else {
                throw Harness(description: "\(where_): unknown operation \(String(describing: object["op"]))")
            }
            guard let id = object["id"] as? String, ids.insert(id).inserted else {
                throw Harness(description: "\(where_): a missing or duplicate case id")
            }
            guard let input = object["input"] as? [String: Any], let expect = object["expect"] as? [String: Any] else {
                throw Harness(description: "\(where_): a case needs input and expect")
            }
            if let problem = try evaluate(id: id, input: input, expect: expect) { failures.append(problem) }
        }
        return (Array(ids), failures)
    }

    /// One case through the production constructor; nil when it answered as expected.
    private func evaluate(id: String, input: [String: Any], expect: [String: Any]) throws -> String? {
        let decoded = try decode(input)
        do {
            let term = try CapturedTerm.make(
                term: decoded.term, trigger: decoded.trigger, acquisition: decoded.acquisition,
                confidence: decoded.confidence, source: decoded.source, pointer: decoded.pointer,
                box: decoded.box, context: decoded.context)
            guard expect["status"] as? String == "valid" else {
                return "\(id): expected \(expect["code"] ?? "invalid"), got a value"
            }
            guard let wanted = expect["value"] as? [String: Any] else { return "\(id): expect.value is missing" }
            let got = encode(term)
            return same(got, wanted) ? nil : "\(id): value differs\n  got: \(json(got))\n want: \(json(wanted))"
        } catch {
            guard expect["status"] as? String == "invalid" else {
                return "\(id): refused (\(code(error))), expected a value"
            }
            let wanted = expect["code"] as? String ?? ""
            return code(error) == wanted ? nil : "\(id): refused as \(code(error)), wanted \(wanted)"
        }
    }

    // MARK: - The fixture grammar, decoded and encoded

    private struct Decoded {
        let term: String
        let trigger: CaptureTrigger
        let acquisition: CaptureAcquisition
        let confidence: Double
        let source: SourceApp
        let pointer: PointerSample?
        let box: WordBox
        let context: ContextOutcome
    }

    private func decode(_ input: [String: Any]) throws -> Decoded {
        func string(_ value: Any?, _ what: String) throws -> String {
            guard let text = value as? String else { throw Harness(description: "\(what) is not a string") }
            return text
        }
        func number(_ value: Any?, _ what: String) throws -> Double {
            if let n = value as? NSNumber, !(value is String) { return n.doubleValue }
            if let special = value as? [String: Any], let kind = special["special"] as? String {
                switch kind {
                case "nan": return .nan
                case "+inf": return .infinity
                case "-inf": return -.infinity
                default: throw Harness(description: "\(what) has an unknown special \(kind)")
                }
            }
            throw Harness(description: "\(what) is not a number")
        }
        func integer(_ value: Any?, _ what: String) throws -> Int {
            if let text = value as? String {
                if text == "not-found" { return NSNotFound }
                guard let i = Int(text) else { throw Harness(description: "\(what) is not an integer string") }
                return i
            }
            if let n = value as? NSNumber { return n.intValue }
            throw Harness(description: "\(what) is not an integer")
        }
        func point(_ value: Any?, _ what: String) throws -> DownPoint {
            guard let object = value as? [String: Any] else { throw Harness(description: "\(what) is not a point") }
            return DownPoint(x: try number(object["x"], "\(what).x"), y: try number(object["y"], "\(what).y"))
        }

        let term = try string(input["term"], "term")
        guard let trigger = CaptureTrigger(rawValue: try string(input["trigger"], "trigger")) else {
            throw Harness(description: "unknown trigger \(String(describing: input["trigger"]))")
        }
        guard let acquisition = CaptureAcquisition(rawValue: try string(input["acquisition"], "acquisition")) else {
            throw Harness(description: "unknown acquisition \(String(describing: input["acquisition"]))")
        }
        let confidence = try number(input["confidence"], "confidence")
        let source: SourceApp
        if let object = input["source"] as? [String: Any] {
            source = SourceApp(bundleID: object["bundleID"] as? String)
        } else {
            source = SourceApp(bundleID: nil)
        }
        let pointer = input["pointer"] is NSNull ? nil : PointerSample(point: try point(input["pointer"], "pointer"), at: nil)
        let box = try decodeBox(input["box"])
        let context = try decodeContext(input["context"])
        return Decoded(term: term, trigger: trigger, acquisition: acquisition, confidence: confidence,
                       source: source, pointer: pointer, box: box, context: context)
    }

    private func decodeBox(_ value: Any?) throws -> WordBox {
        guard let object = value as? [String: Any], let kind = object["kind"] as? String else {
            throw Harness(description: "box is not an object with a kind")
        }
        func number(_ v: Any?, _ what: String) throws -> Double {
            if let n = v as? NSNumber { return n.doubleValue }
            if let special = v as? [String: Any], let kind = special["special"] as? String {
                switch kind {
                case "nan": return .nan
                case "+inf": return .infinity
                case "-inf": return -.infinity
                default: throw Harness(description: "\(what) has an unknown special \(kind)")
                }
            }
            throw Harness(description: "\(what) is not a number")
        }
        switch kind {
        case "absent":
            return .absent
        case "measured":
            guard let rect = object["rect"] as? [String: Any],
                  let quality = WordBounds.Quality(rawValue: object["quality"] as? String ?? "") else {
                throw Harness(description: "a measured box needs a rect and a quality")
            }
            let cg = CGRect(x: try number(rect["x"], "rect.x"), y: try number(rect["y"], "rect.y"),
                            width: try number(rect["width"], "rect.width"), height: try number(rect["height"], "rect.height"))
            return .measured(ReadBounds(rect: DownRect(cg), quality: quality))
        case "clickPlacement":
            guard let p = object["point"] as? [String: Any] else { throw Harness(description: "a click placement needs a point") }
            return .clickPlacement(DownPoint(x: try number(p["x"], "point.x"), y: try number(p["y"], "point.y")))
        default:
            throw Harness(description: "unknown box kind \(kind)")
        }
    }

    private func decodeContext(_ value: Any?) throws -> ContextOutcome {
        guard let object = value as? [String: Any], let kind = object["kind"] as? String else {
            throw Harness(description: "context is not an object with a kind")
        }
        switch kind {
        case "available":
            guard let sentence = object["sentence"] as? String, let term = object["term"] as? [String: Any] else {
                throw Harness(description: "an available context needs a sentence and a term range")
            }
            let start: Int = try {
                if let text = term["start"] as? String {
                    if text == "not-found" { return NSNotFound }
                    guard let i = Int(text) else { throw Harness(description: "term.start is not an integer") }
                    return i
                }
                throw Harness(description: "term.start is not an integer string")
            }()
            guard let lengthText = term["length"] as? String, let length = Int(lengthText) else {
                throw Harness(description: "term.length is not an integer string")
            }
            var cut: CutEnds = []
            for name in object["cut"] as? [String] ?? [] {
                switch name {
                case "start": cut.insert(.start)
                case "end": cut.insert(.end)
                default: throw Harness(description: "unknown cut end \(name)")
                }
            }
            var gap: InternalGap?
            if let name = object["gap"] as? String {
                guard let known = InternalGap(rawValue: name) else { throw Harness(description: "unknown gap \(name)") }
                gap = known
            }
            return .available(sentence: sentence, term: NSRange(location: start, length: length), cut: cut, gap: gap)
        case "pending":
            guard let text = object["handle"] as? String, let id = UInt64(text) else {
                throw Harness(description: "a pending context needs a handle string")
            }
            return .pending(PendingContextHandle(id: id))
        case "unavailable":
            guard let name = object["reason"] as? String, let reason = ContextUnavailable(rawValue: name) else {
                throw Harness(description: "unknown unavailable reason \(String(describing: object["reason"]))")
            }
            return .unavailable(reason)
        default:
            throw Harness(description: "unknown context kind \(kind)")
        }
    }

    private func encode(_ term: CapturedTerm) -> [String: Any] {
        var pointer: Any = NSNull()
        if let p = term.pointer { pointer = ["x": p.point.cg.x, "y": p.point.cg.y] }
        var source: Any = NSNull()
        if let bundle = term.source.bundleID { source = ["bundleID": bundle] }
        return [
            "term": term.term,
            "trigger": term.trigger.rawValue,
            "acquisition": term.acquisition.rawValue,
            "confidence": term.confidence,
            "source": source,
            "pointer": pointer,
            "box": encode(term.box),
            "context": encode(term.context),
        ]
    }

    private func encode(_ box: WordBox) -> [String: Any] {
        switch box {
        case .absent:
            return ["kind": "absent"]
        case .measured(let bounds):
            return ["kind": "measured",
                    "rect": ["x": bounds.rect.cg.origin.x, "y": bounds.rect.cg.origin.y,
                             "width": bounds.rect.cg.width, "height": bounds.rect.cg.height],
                    "quality": bounds.quality.rawValue]
        case .clickPlacement(let point):
            return ["kind": "clickPlacement", "point": ["x": point.cg.x, "y": point.cg.y]]
        }
    }

    private func encode(_ context: ContextOutcome) -> [String: Any] {
        switch context {
        case .available(let sentence, let range, let cut, let gap):
            var ends: [String] = []
            if cut.contains(.start) { ends.append("start") }
            if cut.contains(.end) { ends.append("end") }
            return ["kind": "available", "sentence": sentence,
                    "term": ["start": String(range.location), "length": String(range.length)],
                    "cut": ends, "gap": gap?.rawValue as Any? ?? NSNull()]
        case .pending(let handle):
            return ["kind": "pending", "handle": String(handle.id)]
        case .unavailable(let reason):
            return ["kind": "unavailable", "reason": reason.rawValue]
        }
    }

    // MARK: - Comparison: ordinal UTF-16, complete

    private func same(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (let x as String, let y as String):
            return Array(x.utf16) == Array(y.utf16)
        case (let x as NSNumber, let y as NSNumber) where !(a is String) && !(b is String):
            return x.doubleValue == y.doubleValue
        case (let x as [String: Any], let y as [String: Any]):
            guard x.keys.sorted() == y.keys.sorted() else { return false }
            return x.allSatisfy { key, value in y[key].map { same(value, $0) } ?? false }
        case (let x as [Any], let y as [Any]):
            guard x.count == y.count else { return false }
            return zip(x, y).allSatisfy { same($0, $1) }
        case (_ as NSNull, _ as NSNull):
            return true
        default:
            return false
        }
    }

    private func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }

    private func code(_ error: CaptureValueError) -> String {
        switch error {
        case .term: "term"
        case .confidence: "confidence"
        case .geometry: "geometry"
        case .contextTooLong: "context.too-long"
        case .range: "range"
        case .rangeSplitsCharacter: "range.splits-character"
        }
    }
}
