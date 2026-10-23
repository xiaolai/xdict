import CoreGraphics

/// **What the capture lab is asked to do** (plan-capture WI-4; ported from XiaolaiDict's `LaunchArguments.readPoint`): one
/// command, `--read-point X Y`, a global point in points with y down, the space hover's reader works in. A verification
/// command that accepted a typo would report success for something nobody asked for, so anything else is refused.
enum LabCommand: Equatable {
    case readPoint(CGPoint)
    /// What this lab is granted: Accessibility and Screen Recording, asked of the APIs that never prompt.
    case access

    static let readPointFlag = "--read-point"
    static let accessFlag = "--access"
    static let usage = "usage: XDictCaptureLab --read-point X Y   (a global point in points, y down)"
        + " | XDictCaptureLab --access"

    struct UsageError: Error, Equatable {
        let message: String
    }

    static func parse(_ arguments: [String]) -> Result<LabCommand, UsageError> {
        if arguments == [accessFlag] { return .success(.access) }
        guard arguments.first == readPointFlag else { return .failure(UsageError(message: usage)) }
        let numbers = arguments.dropFirst()
        guard numbers.count == 2, let first = numbers.first, let last = numbers.last else {
            return .failure(UsageError(message: "\(readPointFlag) needs X and Y"))
        }
        guard let x = Double(first), let y = Double(last), x.isFinite, y.isFinite else {
            return .failure(UsageError(message: "\(readPointFlag) needs two numbers, not \(numbers.joined(separator: " "))"))
        }
        return .success(.readPoint(CGPoint(x: x, y: y)))
    }
}
