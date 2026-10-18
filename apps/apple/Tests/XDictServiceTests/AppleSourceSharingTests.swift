import Foundation
import Testing
import XDictAppleImport
import XDictAppleSource
import XDictContract
@testable import XDictService
import XDictTestSupport

/// **The app and the service say the same thing about one bundle** (ADR-0011 decision 7; plan WI-5): the source
/// revision the app computes over an installed bundle is the one the service stamps on its conversion of the app's copy,
/// and the converter revision the app compares with is the converter's own. Otherwise an update would be offered for
/// nothing, at every launch, or never.
struct AppleSourceSharingTests {
    @Test func theAppsRevisionOfABundleIsTheServicesOfItsCopy() throws {
        let staging = try AppleStaging()
        let installed = staging.base.appending(path: "installed")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let bundle = try SyntheticAppleBundle.make(in: installed)
        try FileManager.default.createDirectory(at: bundle.appending(path: "Contents/Resources/en.lproj"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: bundle.appending(path: "Contents/Resources/en.lproj/InfoPlist.strings"))
        let appSays = try XDictAppleSource.Manifest.revision(of: bundle)
        let id = try SnapshotCopy.copy(bundle, into: staging.store.root)
        let converted = try staging.convert(id).get()
        #expect(converted.sourceRevision == appSays)
    }

    @Test func theAppsConverterRevisionIsTheConvertersOwn() {
        #expect(AppleConverter.revision == UInt32(AppleImport.converterRevision))
        #expect(UInt32(AppleImports.converterRevision) == AppleConverter.revision)
    }
}
