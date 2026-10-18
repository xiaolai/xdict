import Foundation
import Testing
import XDictLibrary
@testable import XDictUI

/// **Convert Again shows that something is happening** (owner, 2026-10-18: it showed nothing, so a reader would think
/// nothing happened). The selected dictionary's box says what its conversion is doing, with the service's own count when
/// it has one.
struct AppleConversionLineTests {
    @Test func noStepIsNoLine() {
        #expect(AppleConversionLine.of(nil) == nil)
        #expect(AppleConversionLine.of(.added(UUID())) == nil)
        #expect(AppleConversionLine.of(.cancelled) == nil)
    }

    @Test func waitingAndCopyingAreWorkWithNoCountYet() {
        #expect(AppleConversionLine.of(.waiting) == .working(fraction: nil, cancellable: true))
        #expect(AppleConversionLine.of(.copying) == .working(fraction: nil, cancellable: true))
    }

    @Test func convertingCarriesTheServicesCount() {
        #expect(AppleConversionLine.of(.converting(done: 0, total: 0)) == .working(fraction: nil, cancellable: true))
        #expect(AppleConversionLine.of(.converting(done: 1, total: 4)) == .working(fraction: 0.25, cancellable: true))
        #expect(AppleConversionLine.of(.converting(done: 9, total: 4)) == .working(fraction: 1, cancellable: true))
    }

    @Test func cancellingCannotBeCancelledAgain() {
        #expect(AppleConversionLine.of(.cancelling) == .working(fraction: nil, cancellable: false))
    }

    @Test func aFailureIsALineToo() {
        #expect(AppleConversionLine.of(.failed(.notAdded)) == .failed(.notAdded))
    }
}
