import AppKit
import Foundation
import Synchronization
import Testing
@testable import XDictCaptureMac

/// **The warm-up is one recognition of one small drawn image, off the main thread**, its answer discarded: no screen is
/// captured (it is handed the image, never a window), and the caller is not held.
struct RecognitionWarmUpJobTests {
    private struct Call {
        let width: Int, height: Int, onMain: Bool, inSwiftTask: Bool, background: Bool
    }

    /// **And outside Swift concurrency's pool, at background quality of service** (verifier, 2026-10-19): a 25-second
    /// first recognition on a cooperative thread would hold one of the few the whole app's tasks share. Red where it runs
    /// as a Swift task, or above background.
    @Test @MainActor func theWarmUpReadsOneSmallDrawnImageOnABackgroundQueue() async {
        let seen = Mutex<[Call]>([])
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            ScreenTextRecogniser.warmUp(recognise: { image in
                let inTask = withUnsafeCurrentTask { $0 != nil }
                seen.withLock {
                    $0.append(Call(width: image.width, height: image.height, onMain: Thread.isMainThread,
                                   inSwiftTask: inTask, background: qos_class_self() == QOS_CLASS_BACKGROUND))
                }
                return []
            }, done: { done.resume() })
        }
        let calls = seen.withLock { $0 }
        #expect(calls.count == 1, "\(calls.count) recognitions")
        let small = calls.allSatisfy { $0.width <= 512 && $0.height <= 64 }
        let offMain = calls.allSatisfy { !$0.onMain }
        let outsideTasks = calls.allSatisfy { !$0.inSwiftTask }
        let background = calls.allSatisfy { $0.background }
        #expect(small, "the image is not small")
        #expect(offMain, "the warm-up ran on the main thread")
        #expect(outsideTasks, "the warm-up ran on Swift concurrency's pool")
        #expect(background, "the warm-up ran above background")
    }

    /// The image has something drawn in it, so Vision's text models, not only its setup, are loaded.
    @Test func theImageHasInkOnIt() throws {
        let image = try #require(ScreenTextRecogniser.warmUpImage())
        let data = try #require(image.dataProvider?.data as Data?)
        #expect(Set(data).count > 2, "the warm-up image is blank")
    }
}
