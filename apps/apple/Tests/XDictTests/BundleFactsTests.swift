import Foundation
import Testing
import XDictTestSupport

/// What the tracked files say the bundle is, before any bundle exists: the identities ADR-0001 fixes, an executable
/// each plist names that the package builds, one version across both, and each binary's entitlements exactly.
/// `Tools/build-bundle.sh` asks the same of the assembled bundle; this is the half that fails in `swift test`.
struct BundleFactsTests {
    @Test func theAppIsAiXdictApp() throws {
        let app = try PlatformFloorTests.plist("Resources/Info.plist")
        #expect(app["CFBundleIdentifier"] as? String == "ai.xdict.app")
        #expect(app["CFBundlePackageType"] as? String == "APPL")
        #expect(app["CFBundleExecutable"] as? String == "XDict")
        #expect(try Self.executables().contains("XDict"))
    }

    @Test func theServiceIsItsDictionaryService() throws {
        let service = try PlatformFloorTests.plist("Resources/DictionaryService-Info.plist")
        #expect(service["CFBundleIdentifier"] as? String == "ai.xdict.app.DictionaryService")
        #expect(service["CFBundlePackageType"] as? String == "XPC!")
        #expect(service["CFBundleExecutable"] as? String == "XDictService")
        #expect((service["XPCService"] as? [String: Any])?["ServiceType"] as? String == "Application")
        #expect(try Self.executables().contains("XDictService"))
    }

    @Test func bothDeclareOneVersion() throws {
        let app = try PlatformFloorTests.plist("Resources/Info.plist")
        let service = try PlatformFloorTests.plist("Resources/DictionaryService-Info.plist")
        let version = app["CFBundleShortVersionString"] as? String
        #expect(version != nil && version == service["CFBundleShortVersionString"] as? String)
    }

    /// **The service is sandboxed and may open nothing**: no file entitlement, no network. A file reaches it as a
    /// descriptor the app opened (plan-macos-v1, choice 1). The app is not sandboxed and asks for nothing.
    @Test func eachBinaryHasExactlyItsEntitlements() throws {
        let service = try PlatformFloorTests.plist("Resources/DictionaryService.entitlements")
        #expect(service.count == 1 && service["com.apple.security.app-sandbox"] as? Bool == true, "\(service)")
        let app = try PlatformFloorTests.plist("Resources/XDict.entitlements")
        #expect(app.isEmpty, "\(app)")
    }

    /// The app declares the languages the catalog carries, and only those: English and Simplified Chinese
    /// (plan-macos-v1, the owner's decision of 2026-10-14).
    @Test func theAppDeclaresItsTwoLanguages() throws {
        let app = try PlatformFloorTests.plist("Resources/Info.plist")
        #expect(app["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(app["CFBundleLocalizations"] as? [String] == ["en", "zh-Hans"])
    }

    static func executables() throws -> Set<String> {
        Set(try Manifest.dump().targets.values.filter { $0.type == "executable" }.map(\.name))
    }
}
