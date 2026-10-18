import XDictAppleImport

/// **Apple's dictionaries are converted here, in the service, and nowhere else** (ADR-0011 decision 3): a bundle is
/// untrusted binary input (ADR-0001), so the converter is linked into this process alone (`ModuleBoundaryTests`).
/// `convertApple(staging:)` arrives with plan WI-4; until then the service names the converter revision it would stamp
/// on what it converts (ADR-0011 decision 7).
enum AppleImports {
    static let converterRevision = AppleImport.converterRevision
}
