import Foundation
import Testing
import XDictContract

/// **The render context** (ADR-0007 decision 14; ADR-0010 Q3): the ceiling, and the reader's "Original style", which
/// crosses to the service as asked and is off for the reader's default context.
struct RenderContextTests {
    @Test func originalStyleCrossesTheWireAndIsOffByDefault() throws {
        #expect(RenderContext.reader.originalStyle == false)
        #expect(RenderContext(maxBodyBytes: 9).originalStyle == false)
        let asked = RenderContext(maxBodyBytes: 9, originalStyle: true)
        let read = try JSONDecoder().decode(RenderContext.self, from: JSONEncoder().encode(asked))
        #expect(read == asked)
        #expect(read.originalStyle)
    }
}
