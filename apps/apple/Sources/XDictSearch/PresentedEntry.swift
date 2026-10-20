/// **Which lookup's entry the view was last asked to show** — by the lookup's serial and the shown entry's serial together
/// (plan-capture WI-4 rule 3; audit-fix 2026-10-20 finding 1).
///
/// A document's finish is the only evidence that an entry was drawn, and it carries no identity of its own. Two ways of
/// losing that identity are closed here:
///
/// - the adapter used to take the model's **current** query for the finished document's (`LookupAnywhere.entryFinished`),
///   so a document that finished in the gap between a newer lookup and its entry request was credited to the newer term;
/// - the **shown serial alone** is not enough, because while a newer lookup awaits its first result `model.shown` still
///   names the older lookup's entry: the older document's finish would pass a shown-serial check and be credited to the
///   newer term. The lookup's own serial is therefore part of the identity.
///
/// A finish counts only while the model still shows the entry of the lookup the entry view was asked for; a newer lookup,
/// a closed panel, or nothing ever asked makes the older document's finish change nothing.
public struct PresentedEntry: Sendable, Equatable {
    /// The serial of the `Shown` the entry view was last asked to load; nil before the first ask.
    public private(set) var shownSerial: Int?
    /// The serial of the lookup that `Shown` belonged to; nil before the first ask.
    public private(set) var lookupSerial: Int?

    public init() {}

    /// The entry view was handed `serial`'s document for `lookup` (a show that failed to reach WebKit does not count).
    public mutating func asked(serial: Int, lookup: Int?) {
        shownSerial = serial
        lookupSerial = lookup
    }

    /// Whether the lookup shown now — its own serial and the shown entry's — is the one the entry view was asked to show.
    /// Nil at either side is not current: a panel that showed nothing was not drawn, and a serial compared to nothing
    /// proves nothing.
    public func isCurrent(serial shown: Int?, lookup: Int?) -> Bool {
        guard let asked = shownSerial, let askedLookup = lookupSerial, let shown, let lookup else { return false }
        return shown == asked && lookup == askedLookup
    }
}
