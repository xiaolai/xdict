import Foundation
import XDictLibrary

/// What the selected Apple dictionary's conversion is doing, for the box under the Settings table: its progress while it
/// waits, copies or converts, or why it failed. A finished or cancelled one shows no line (the row it leaves says the rest).
enum AppleConversionLine: Equatable {
    case working(fraction: Double?, cancellable: Bool)
    case failed(AppleImportFailure)

    static func of(_ step: AppleImportStep?) -> AppleConversionLine? {
        switch step {
        case nil, .added, .cancelled: nil
        case .waiting, .copying: .working(fraction: nil, cancellable: true)
        case .converting(let done, let total):
            .working(fraction: total > 0 ? min(Double(done) / Double(total), 1) : nil, cancellable: true)
        case .cancelling: .working(fraction: nil, cancellable: false)
        case .failed(let failure): .failed(failure)
        }
    }
}
