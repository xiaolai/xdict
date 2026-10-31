//! **A bounded, evenly spaced sample of a dictionary's records** (the owner's performance defect, 2026-10-31): a
//! question answerable from a few records — does this edition carry a markup signature at all? — is asked before a
//! store walks every record to answer it. One reader, so every such check reads the same sample under the same bounds,
//! and answers it with the same three-way rule: found, a confident negative, or unknown.
//!
//! **A negative is proof only when every record the sample selected was examined** (audit, 2026-10-31): a sampled
//! record skipped as oversized was never read and may carry the signature, so that verdict is unknown and the caller
//! falls back to the full pass. The 64 evenly spaced points are the sampling's accepted coverage; it is not a pass
//! over every record.

use xdict_mdx::File;

use crate::CoreError;

/// How many records a signature check reads, evenly spaced through the file.
pub(crate) const SIGNATURE_SAMPLES: usize = 64;
/// The most one sampled record may cost, as stored: past it the record is skipped rather than read, so a hostile or
/// huge entry cannot make the check allocate.
pub(crate) const SIGNATURE_RECORD_BYTES: u64 = 256 << 10;

/// **Whether any of at most `samples` evenly spaced records of `file` matches `signature`**, answering only what the
/// sample can prove:
///
/// - `Some(true)` at the first match;
/// - `Some(false)` only when every sampled record was examined and none matched;
/// - `None` when the sample is incomplete — no record could be examined (an empty file), or any sampled record was
///   past `record_bytes` and so was not read. **An incomplete negative is not proof**: the skipped record, or one
///   beyond the sampled points, may carry the signature, so the caller reads in full rather than answer "no markup".
///
/// Both ends are sampled and neighbours span the file evenly, so markup carried by most of a dictionary's entries is
/// seen wherever its records fall. Reading stops at the first match, so a positive costs one record.
pub(crate) fn any_sampled_record(
    file: &File,
    samples: usize,
    record_bytes: u64,
    signature: impl Fn(&str) -> bool,
) -> Result<Option<bool>, CoreError> {
    let len = file.len();
    let wanted = samples.min(len);
    if wanted == 0 {
        return Ok(None);
    }
    let mut examined = 0usize;
    for k in 0..wanted {
        // Evenly spaced over the whole file. A `u128` product keeps a very long file from overflowing the multiply.
        let i = (k as u128 * len as u128 / wanted as u128) as usize;
        let size = file.record_size(i).map_err(|error| with_record(CoreError::from(error), i))?;
        if size > record_bytes {
            continue;
        }
        let record = file.record(i).map_err(|error| with_record(CoreError::from(error), i))?;
        examined += 1;
        if signature(&String::from_utf8_lossy(&record.data)) {
            return Ok(Some(true));
        }
    }
    // **Only a sample that examined every record it selected can answer "no"**: one skipped as oversized leaves a
    // record unread, and the store's full pass must decide.
    Ok(if examined == wanted { Some(false) } else { None })
}

/// One record's own error, with the record's number added and its kind kept.
pub(crate) fn with_record(error: CoreError, i: usize) -> CoreError {
    match error {
        CoreError::Malformed { detail } => CoreError::Malformed { detail: format!("record {i}: {detail}") },
        CoreError::Io { kind, detail } => CoreError::Io { kind, detail: format!("record {i}: {detail}") },
        other => other,
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

    use super::*;
    use xdict_mdx::Kind;
    use xdict_mdx_writer::{Entry, Spec, write};

    fn dictionary(entries: &[Entry]) -> File {
        File::from_source(Box::new(write(&Spec::mdx(), entries).unwrap()), Some(Kind::Mdx)).unwrap()
    }

    /// **The sample answers only what it examined**: a match in a sampled record is found, a complete sample with no
    /// match is a confident negative, and an empty file examined nothing.
    #[test]
    fn the_sample_answers_only_what_it_examined() {
        let plain: Vec<Entry> = (0..200).map(|n| Entry::text(&format!("w{n}"), "no markup")).collect();
        let file = dictionary(&plain);
        assert_eq!(any_sampled_record(&file, 64, 256 << 10, |text| text.contains("ocd_co")).unwrap(), Some(false));
        // One record in the middle carries the signature: the evenly spaced sample still reaches it, and the read
        // stops there.
        let mut marked = plain;
        marked[100] = Entry::text("w100", r#"<span class="ocd_co">major</span>"#);
        let file = dictionary(&marked);
        assert_eq!(any_sampled_record(&file, 64, 256 << 10, |text| text.contains("ocd_co")).unwrap(), Some(true));
        // An empty file examined nothing.
        assert_eq!(any_sampled_record(&dictionary(&[]), 64, 256 << 10, |_| true).unwrap(), None);
    }

    /// **A skipped record makes the answer unknown, never a negative** (audit, 2026-10-31): a record past the byte
    /// bound was never read, and it may carry the signature, so the caller must fall back to the full pass. A file
    /// whose only record is over the bound answers `None`, not `false`.
    #[test]
    fn a_skipped_record_makes_the_answer_unknown() {
        // A second record large enough that its stored size is known to differ from the first's.
        let body: String = (0..1024).map(|n| format!("{n:04x}")).collect();
        let file = dictionary(&[Entry::text("small", "no markup"), Entry::text("big", &body)]);
        // The writer orders records by key, so the sizes, not the indices, say which is which.
        let (first, second) = (file.record_size(0).unwrap(), file.record_size(1).unwrap());
        let (small, big) = (first.min(second), first.max(second));
        assert!(big > small, "the fixture must have one record on each side of the bound: {small} vs {big}");
        assert_eq!(
            any_sampled_record(&file, 2, big, |_| false).unwrap(),
            Some(false),
            "every sampled record was examined and none matched"
        );
        assert_eq!(
            any_sampled_record(&file, 2, small, |_| false).unwrap(),
            None,
            "the larger record was skipped, so the negative is not proof"
        );
        // The only record is over the bound: nothing was examined, and the answer is unknown rather than "no markup".
        let file = dictionary(&[Entry::text("big", &body)]);
        assert_eq!(any_sampled_record(&file, 64, 1, |_| true).unwrap(), None);
    }
}
