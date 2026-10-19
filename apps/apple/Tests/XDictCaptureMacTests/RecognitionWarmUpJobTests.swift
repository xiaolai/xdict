import AppKit
import Foundation
import Synchronization
import Testing
@testable import XDictCaptureMac

/// **The warm-up is one recognition of one small drawn image, off the main thread**, its answer discarded: no screen is
/// captured (it is handed the image, never a window), and the caller is not held (a detached, low-priority task).
struct RecognitionWarmUpJobTests {
    @Test @MainActor func theWarmUpReadsOneSmallDrawnImageOffTheMainThread() async {
        let seen = Mutex<[(width: Int, height: Int, onMain: Bool)]>([])
        let job = ScreenTextRecogniser.warmUp { image in
            seen.withLock { $0.append((image.width, image.height, Thread.isMainThread)) }
            return []
        }
        await job.value
        let calls = seen.withLock { $0 }
        #expect(calls.count == 1, "\(calls.count) recognitions")
        #expect(calls.allSatisfy { $0.width <= 512 && $0.height <= 64 }, "the image is not small: \(calls)")
        #expect(calls.allSatisfy { !$0.onMain }, "the warm-up ran on the main thread")
    }

    /// The image has something drawn in it, so Vision's text models, not only its setup, are loaded.
    @Test func theImageHasInkOnIt() throws {
        let image = try #require(ScreenTextRecogniser.warmUpImage())
        let data = try #require(image.dataProvider?.data as Data?)
        #expect(Set(data).count > 2, "the warm-up image is blank")
    }
}
