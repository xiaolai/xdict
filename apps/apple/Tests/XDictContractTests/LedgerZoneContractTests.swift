import Foundation
import Testing
@testable import XDictContract

/// **The zone travels as its offsets, and the answers keep what the core could not do** (audit 2026-11-05: L5d, M5,
/// M16).
struct LedgerZoneContractTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin")
    /// 2026-10-25 01:00 UTC, when Berlin leaves summer time.
    private static let change = Date(timeIntervalSince1970: 1_792_890_000)

    /// A zone with daylight saving: the offset at the span's start, then the change at its own instant.
    @Test func aZoneWithDaylightSavingListsTheChangeInsideTheSpan() throws {
        let zone = ZoneOffset.zone(try #require(Self.berlin), around: Self.change.addingTimeInterval(86_400))
        #expect(zone.map(\.seconds) == [7_200, 3_600])
        #expect(zone.last?.from == Self.change.timeIntervalSince1970)
        #expect(zone.first.map { $0.from < Self.change.timeIntervalSince1970 } == true)
    }

    /// A zone without daylight saving, and a span with no change in it, are one entry: the offset that holds.
    @Test func aZoneWithoutAChangeIsOneEntry() throws {
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        #expect(ZoneOffset.zone(shanghai, around: Self.change).map(\.seconds) == [28_800])
        #expect(ZoneOffset.zone(try #require(TimeZone(identifier: "UTC")), around: Self.change).map(\.seconds) == [0])
        let summer = Self.change.addingTimeInterval(-90 * 86_400)
        #expect(ZoneOffset.zone(try #require(Self.berlin), around: summer).map(\.seconds) == [7_200])
    }

    /// The core's words for a re-anchor result, and its `failed` object, decode and encode as written.
    @Test func aFailedReanchorRoundTripsInTheCoresShape() throws {
        let failed = try JSONDecoder().decode([ReanchorResult].self,
                                              from: Data(#"["missing",{"failed":{"detail":"Malformed"}}]"#.utf8))
        #expect(failed == [.missing, .failed(detail: "Malformed")])
        let encoded = try JSONDecoder().decode([ReanchorResult].self, from: JSONEncoder().encode(failed))
        #expect(encoded == failed)
        let report = try JSONDecoder().decode(ReanchorReport.self, from: Data(#"{"outcomes":[],"next":"k"}"#.utf8))
        #expect(report.next == "k")
    }

    /// A sync report names the files it left out.
    @Test func aSyncReportDecodesItsRefusals() throws {
        let json = #"{"exported":1,"peers":1,"added":2,"skipped":0,"refused":[{"file":"b.xdlog","detail":"Malformed"}]}"#
        let report = try JSONDecoder().decode(SyncReport.self, from: Data(json.utf8))
        #expect(report.refused == [SyncRefusal(file: "b.xdlog", detail: "Malformed")])
    }
}
