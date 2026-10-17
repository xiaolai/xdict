//! **The bytes a scan examines, counted in this crate's own tests** (2026-10-17): a scanner calls [`scanned`] with
//! what each search or step read, and a test asks [`counting`] what a run read in all. A count, not a clock: a linear
//! scan of `n` bytes reads about `n`, a quadratic one about `n²`, whatever else the machine is doing. Outside
//! `cfg(test)` [`scanned`] is empty and compiles away.
//!
//! **What it cannot see**: a search that does not report here. A test holding a scanner to its count holds only the
//! steps that report; a search added to such a scanner must report too.

#[cfg(test)]
thread_local! {
    static SCANNED: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// `bytes` more were examined, on this thread.
#[inline(always)]
pub(crate) fn scanned(bytes: usize) {
    #[cfg(test)]
    SCANNED.with(|c| c.set(c.get().saturating_add(u64::try_from(bytes).unwrap_or(u64::MAX))));
    #[cfg(not(test))]
    let _ = bytes;
}

/// What `run` gives, and the bytes it examined on this thread.
#[cfg(test)]
pub(crate) fn counting<T>(run: impl FnOnce() -> T) -> (T, u64) {
    let before = SCANNED.with(std::cell::Cell::get);
    let got = run();
    (got, SCANNED.with(std::cell::Cell::get).saturating_sub(before))
}
