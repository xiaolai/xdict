/// **How asking the dictionary service for its versions at launch failed**, each way its own case: a reader told "it
/// failed" cannot tell a slow service from a missing one, and neither can a log. The app asks through the contract's
/// `versions` (plan-macos-v1 WI-3) and words the outcome as one of these for the launch window (`LaunchStatus`).
public enum HandshakeFailure: Error, Equatable, Sendable {
    /// No answer by the deadline.
    case timedOut(after: Duration)
    /// The connection broke or was refused before an answer: no such service, or one that would not accept us.
    case unreachable(String)
    /// The service answered with a reason instead of versions.
    case refused(String)
    /// The service answered with something that is not versions.
    case unreadable(String)
}
