import AppKit
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

    /// **The service is sandboxed and may open nothing of the reader's**: no file entitlement, no network. A dictionary
    /// reaches it as a descriptor the app opened (plan-macos-v1, choice 1). The app is not sandboxed. Both share one
    /// app group, where Apple dictionary snapshots are staged and converted (ADR-0011 decision 4, amended 2026-10-18);
    /// its team prefix is written as Xcode's `$(TeamIdentifierPrefix)` and substituted at signing from the signing
    /// identity (`Tools/expand-entitlements.sh`), so no team identifier is in a tracked file.
    @Test func eachBinaryHasExactlyItsEntitlements() throws {
        let group = ["$(TeamIdentifierPrefix)ai.xdict.app"]
        let service = try PlatformFloorTests.plist("Resources/DictionaryService.entitlements")
        #expect(service.count == 2 && service["com.apple.security.app-sandbox"] as? Bool == true, "\(service)")
        #expect(service["com.apple.security.application-groups"] as? [String] == group, "\(service)")
        let app = try PlatformFloorTests.plist("Resources/XDict.entitlements")
        #expect(app.count == 1 && app["com.apple.security.application-groups"] as? [String] == group, "\(app)")
    }

    /// The app declares the languages the catalog carries, and only those: English and Simplified Chinese
    /// (plan-macos-v1, the owner's decision of 2026-10-14).
    @Test func theAppDeclaresItsTwoLanguages() throws {
        let app = try PlatformFloorTests.plist("Resources/Info.plist")
        #expect(app["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(app["CFBundleLocalizations"] as? [String] == ["en", "zh-Hans"])
    }

    /// The app icon is the Icon Composer document `Resources/XDict.icon`, compiled by actool into `Assets.car` under
    /// the same name (`Tools/compile-icon.sh`): the plist's name, the document's and actool's `--app-icon` are one.
    @Test func theAppNamesItsIcon() throws {
        let app = try PlatformFloorTests.plist("Resources/Info.plist")
        #expect(app["CFBundleIconName"] as? String == "XDict")
        let document = Manifest.package.appending(path: "Resources/XDict.icon/icon.json")
        #expect(FileManager.default.fileExists(atPath: document.path(percentEncoded: false)))
    }

    /// **The icon's mark is the default reading accent** (owner, 2026-10-17): teal, light and dark, as
    /// the tokens' `[accent] teal` declares it (`Tokens/tokens.toml`). Both are read from source, so changing either alone fails here
    /// rather than drifting. Every platform's set is generated from `icon.json` (`Tools/icons`), so they follow.
    @Test func theIconsMarkIsTheReadingAccent() throws {
        let tokens = try String(contentsOf: Manifest.package.appending(path: "Tokens/tokens.toml"), encoding: .utf8)
        let accents = try #require(tokens.components(separatedBy: "\n[accent]\n").last)
        let declared = try #require(("\n" + accents).firstMatch(of: /\nteal = \{ light = "(#[0-9a-fA-F]{6})", dark = "(#[0-9a-fA-F]{6})"/))
        let (light, dark) = (String(declared.1).uppercased(), String(declared.2).uppercased())

        let data = try Data(contentsOf: Manifest.package.appending(path: "Resources/XDict.icon/icon.json"))
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try #require(document["groups"] as? [[String: Any]])
        let layers = groups.flatMap { $0["layers"] as? [[String: Any]] ?? [] }
        #expect(!layers.isEmpty)
        for layer in layers {
            let fills = try #require(layer["fill-specializations"] as? [[String: Any]], "\(layer["name"] ?? "a layer")")
            var found: [String: String] = [:]
            for fill in fills {
                let solid = try #require((fill["value"] as? [String: Any])?["solid"] as? String)
                found[fill["appearance"] as? String ?? "default"] = try Self.hex(solid)
            }
            #expect(found["default"] == light, "\(layer["name"] ?? "") default is \(found["default"] ?? "none"), not \(light)")
            #expect(found["dark"] == dark, "\(layer["name"] ?? "") dark is \(found["dark"] ?? "none"), not \(dark)")
        }
    }

    /// `srgb:r,g,b,a` (0...1) as `#RRGGBB`.
    static func hex(_ srgb: String) throws -> String {
        let parts = try #require(srgb.hasPrefix("srgb:") ? srgb.dropFirst(5).split(separator: ",").compactMap { Double($0) } : nil)
        try #require(parts.count == 4)
        return "#" + parts.prefix(3).map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    /// **The menu-bar glyph is a template, sized as one**: black on transparency (macOS reads its alpha alone), a
    /// 22 pt box, and ink about 16 pt of it on both axes — fitted on both, touching no edge. Measured off the pixels
    /// CoreSVG draws at 2x, which is what the menu bar draws on a Retina screen.
    @Test func theMenuBarIconIsATemplateGlyph() throws {
        let url = Manifest.package.appending(path: "Resources/MenuBarIcon.svg")
        let image = try #require(NSImage(contentsOf: url))
        #expect(image.size == NSSize(width: 22, height: 22))
        let side = 44
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var xs: [Int] = [], ys: [Int] = [], coloured = 0
        for y in 0..<side { for x in 0..<side {
            let pixel = try #require(rep.colorAt(x: x, y: y))
            guard pixel.alphaComponent >= 0.5 else { continue }
            xs.append(x); ys.append(y)
            if pixel.redComponent > 0.1 || pixel.greenComponent > 0.1 || pixel.blueComponent > 0.1 { coloured += 1 }
        } }
        let (x0, x1, y0, y1) = (try #require(xs.min()), try #require(xs.max()), try #require(ys.min()), try #require(ys.max()))
        let width = Double(x1 + 1 - x0) / Double(side), height = Double(y1 + 1 - y0) / Double(side)
        #expect((0.68...0.78).contains(width) && (0.68...0.78).contains(height), "ink \(width) x \(height) of the box")
        #expect(x0 > 0 && y0 > 0 && x1 < side - 1 && y1 < side - 1, "ink touches the box's edge")
        #expect(coloured == 0, "\(coloured) opaque pixels are not black: a template's colour is thrown away")
    }

    static func executables() throws -> Set<String> {
        Set(try Manifest.dump().targets.values.filter { $0.type == "executable" }.map(\.name))
    }
}
