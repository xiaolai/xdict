/// **What capture tells its consumer, as kinds** (ADR-0014 decision 4): the consumer words each one.
public enum CaptureNotice: String, Sendable, Equatable, CaseIterable {
    /// Recognition needs the Screen Recording grant, which only setup asks for (decision 7).
    case screenRecordingNeeded
    /// A capture is held past its deadline and cannot be cancelled inside the framework: reported, not hidden (decision 6).
    case captureStuck
    /// The reader asked (the gesture completed, the gate said yes) and nothing could be read under the pointer: said, not
    /// left silent (owner's report, 2026-10-19). The kind alone; no word, sentence or app travels with it.
    case nothingUnderPointer
}
