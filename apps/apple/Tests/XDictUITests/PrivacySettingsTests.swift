import Testing
import XDictUI

/// **The permission lists are named as the running macOS names them** (XiaolaiDict `49059e2`): macOS 27 renamed
/// Accessibility to Device Control and Data Access, and Screen Recording to Screen & System Audio Recording.
struct PrivacySettingsTests {
    @Test func theNamesFollowTheRunningSystem() {
        #expect(PrivacySettings.accessibility(majorVersion: 27) == "Device Control and Data Access")
        #expect(PrivacySettings.accessibility(majorVersion: 26) == "Accessibility")
        #expect(PrivacySettings.screenRecording(majorVersion: 27) == "Screen & System Audio Recording")
        #expect(PrivacySettings.screenRecording(majorVersion: 26) == "Screen Recording")
    }
}
