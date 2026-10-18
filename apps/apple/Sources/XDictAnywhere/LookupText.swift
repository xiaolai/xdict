import Foundation
import XDictCaptureMac

/// **What is looked up, from what the reader selected** — by the shortcut or by the Service (plan-macos-v1 WI-8): one
/// rule for both, so the two routes cannot disagree about the same selection.
public enum LookupText {
    /// The longest term looked up: a phrase or an idiom fits, a paragraph selected by mistake does not. XiaolaiDict's 80
    /// was for words; an MDX key can be a whole phrase or a sentence-library entry, so it is wider here.
    public static let maximumLength = 200
    /// The same limit, as capture is handed it: the selection reader refuses a longer term whole, as `term` does.
    public static let admission = TermAdmission(maximumCharacters: maximumLength)

    public enum Outcome: Hashable, Sendable {
        case term(String)
        /// Nothing, or only whitespace.
        case empty
        /// Only punctuation.
        case noWord
        case tooLong(characters: Int)
    }

    public static func term(_ raw: String?) -> Outcome {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        guard let term = SelectedTerm(from: raw) else { return .noWord }
        guard admission.admits(term.text) else { return .tooLong(characters: term.text.count) }
        return .term(term.text)
    }
}
