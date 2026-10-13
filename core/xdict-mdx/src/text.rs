//! The text encodings a file may declare, and the folding a lookup applies.

use std::borrow::Cow;

use crate::{Error, Kind, Unsupported};

/// How a file's keys and (for MDX) records are encoded.
#[derive(Clone, Copy)]
pub(crate) enum Codec {
    Utf8,
    Utf16Le,
    Legacy(&'static encoding_rs::Encoding),
}

impl Codec {
    /// The codec for a file: MDD keys are always UTF-16; an MDX says in `Encoding`, and one that says nothing
    /// is read as UTF-8.
    pub(crate) fn for_file(kind: Kind, declared: &str) -> Result<Self, Error> {
        if kind == Kind::Mdd {
            return Ok(Self::Utf16Le);
        }
        let name = declared.trim().to_ascii_lowercase().replace(['-', '_'], "");
        Ok(match name.as_str() {
            "" | "utf8" => Self::Utf8,
            "utf16" | "utf16le" => Self::Utf16Le,
            "gbk" | "gb2312" | "gb18030" => Self::Legacy(encoding_rs::GB18030),
            "big5" => Self::Legacy(encoding_rs::BIG5),
            // Latin-1 read as windows-1252, its superset, which is what the Encoding Standard does with the
            // label: the 0x80–0x9F range becomes punctuation rather than control characters.
            "iso88591" | "latin1" => Self::Legacy(encoding_rs::WINDOWS_1252),
            _ => return Err(Error::Unsupported(Unsupported::Encoding(declared.to_owned()))),
        })
    }

    /// Bytes in one code unit, which is also the width of a terminating null.
    pub(crate) fn unit(self) -> usize {
        match self {
            Self::Utf16Le => 2,
            Self::Utf8 | Self::Legacy(_) => 1,
        }
    }

    /// [`Self::decode`], and how many bytes could not be read (`core-api.md` §5.6: lossy decoding was silent).
    pub(crate) fn decode_counted(self, bytes: &[u8]) -> (String, u64) {
        let encoding = match self {
            Self::Utf8 => {
                let lossy = bytes.utf8_chunks().map(|c| c.invalid().len() as u64).sum();
                return (String::from_utf8_lossy(bytes).into_owned(), lossy);
            }
            Self::Utf16Le => encoding_rs::UTF_16LE,
            Self::Legacy(encoding) => encoding,
        };
        let mut decoder = encoding.new_decoder_without_bom_handling();
        let mut out = String::with_capacity(bytes.len().saturating_mul(2));
        let (mut rest, mut lossy) = (bytes, 0u64);
        loop {
            let (result, read) = decoder.decode_to_string_without_replacement(rest, &mut out, true);
            rest = rest.get(read..).unwrap_or(&[]);
            match result {
                encoding_rs::DecoderResult::InputEmpty => return (out, lossy),
                encoding_rs::DecoderResult::OutputFull => out.reserve(rest.len().saturating_mul(3) + 16),
                encoding_rs::DecoderResult::Malformed(bad, _) => {
                    lossy += u64::from(bad);
                    out.push('\u{FFFD}');
                }
            }
        }
    }

    /// Decodes text. Invalid sequences become U+FFFD rather than failing the entry: one bad byte in a
    /// 600 KB entry should not hide the other 599,999.
    pub(crate) fn decode(self, bytes: &[u8]) -> String {
        match self {
            Self::Utf8 => String::from_utf8_lossy(bytes).into_owned(),
            Self::Utf16Le => encoding_rs::UTF_16LE.decode_without_bom_handling(bytes).0.into_owned(),
            Self::Legacy(encoding) => encoding.decode_without_bom_handling(bytes).0.into_owned(),
        }
    }
}

/// The folded form of a key under a file's rules: case-folded unless the file is case-sensitive, and with
/// everything but letters and digits removed unless `StripKey="No"`. A key made only of punctuation keeps
/// its case-folded form, so such keys do not all collapse into the empty string.
///
/// Case folding is lower-casing, upper-casing and lower-casing again, each character apart, except that
/// dotless ı is kept. Checked against Unicode 17's full case folding (Python's `str.casefold`) over every
/// code point on 2026-10-13: the two treat exactly the same characters as equal. That is what a lookup
/// needs; the folded text itself differs (Cherokee folds to upper case in Unicode, to lower case here).
/// Lower-casing alone leaves a final sigma apart from σ, and ß, ẞ and ss apart.
pub(crate) fn fold(key: &str, case_sensitive: bool, strip: bool) -> Cow<'_, str> {
    if key.is_ascii() {
        return fold_ascii(key, case_sensitive, strip);
    }
    let cased = if case_sensitive { key.to_owned() } else { case_fold(key) };
    if !strip {
        return Cow::Owned(cased);
    }
    let stripped: String = cased.chars().filter(|c| c.is_alphanumeric()).collect();
    Cow::Owned(if stripped.is_empty() { cased } else { stripped })
}

/// [`fold`] for ASCII text, which is most keys (99.4 % of TLD's), without allocating when the key is already
/// in its folded form. ASCII folds to ASCII: lower case, and the letters and digits kept when stripping.
fn fold_ascii(key: &str, case_sensitive: bool, strip: bool) -> Cow<'_, str> {
    let keep = |b: u8| !strip || b.is_ascii_alphanumeric();
    let unchanged = key.bytes().all(|b| keep(b) && (case_sensitive || !b.is_ascii_uppercase()));
    if unchanged {
        return Cow::Borrowed(key);
    }
    let cased = |b: u8| if case_sensitive { b } else { b.to_ascii_lowercase() };
    let stripped: String = key.bytes().filter(|&b| keep(b)).map(|b| char::from(cased(b))).collect();
    if stripped.is_empty() {
        Cow::Owned(key.bytes().map(|b| char::from(cased(b))).collect())
    } else {
        Cow::Owned(stripped)
    }
}

/// [`fold`]'s text, appended to `out` with no other allocation: measured first, then reserved fallibly and
/// written, so that building an index asks for a key's folding once, as an error it can return. One long key
/// can fold to three times its size (ΐ), which is too much to ask for without being able to say no.
pub(crate) fn fold_into(
    key: &str,
    case_sensitive: bool,
    strip: bool,
    out: &mut Vec<u8>,
) -> Result<(), std::collections::TryReserveError> {
    let (all, kept) = measure(key, case_sensitive);
    let filter = strip && kept > 0;
    out.try_reserve_exact(if filter { kept } else { all })?;
    if key.is_ascii() {
        let cased = |b: u8| if case_sensitive { b } else { b.to_ascii_lowercase() };
        out.extend(key.bytes().filter(|b| !filter || b.is_ascii_alphanumeric()).map(cased));
        return Ok(());
    }
    let mut buf = [0u8; 4];
    cased_chars(key, case_sensitive, |c| {
        if !filter || c.is_alphanumeric() {
            out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
        }
    });
    Ok(())
}

/// The length of [`fold`]'s text, found without writing it.
pub(crate) fn fold_len(key: &str, case_sensitive: bool, strip: bool) -> usize {
    let (all, kept) = measure(key, case_sensitive);
    if strip && kept > 0 { kept } else { all }
}

/// The length of `key` case-folded, and of the letters and digits in it: what folding writes unstripped and
/// stripped.
fn measure(key: &str, case_sensitive: bool) -> (usize, usize) {
    if key.is_ascii() {
        return (key.len(), key.bytes().filter(u8::is_ascii_alphanumeric).count());
    }
    let (mut all, mut kept) = (0usize, 0usize);
    cased_chars(key, case_sensitive, |c| {
        all += c.len_utf8();
        if c.is_alphanumeric() {
            kept += c.len_utf8();
        }
    });
    (all, kept)
}

/// The characters of `key` as [`fold`] cases them, one at a time: as they are when the file is case-sensitive,
/// else [`case_fold`]'s, without the string.
fn cased_chars(key: &str, case_sensitive: bool, mut each: impl FnMut(char)) {
    for c in key.chars() {
        if case_sensitive || c == 'ı' {
            each(c);
            continue;
        }
        for lower in c.to_lowercase() {
            for upper in lower.to_uppercase() {
                upper.to_lowercase().for_each(&mut each);
            }
        }
    }
}

fn case_fold(key: &str) -> String {
    let mut out = String::with_capacity(key.len());
    for c in key.chars() {
        if c == 'ı' {
            out.push(c);
            continue;
        }
        for lower in c.to_lowercase() {
            for upper in lower.to_uppercase() {
                out.extend(upper.to_lowercase());
            }
        }
    }
    out
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    /// Folding into a buffer writes exactly what [`fold`] returns, and measures it exactly: every scalar value
    /// alone and the cases folding treats apart (dotless ı, ΐ's growth, ß, final sigma, punctuation-only keys
    /// that keep their case-folded form, the empty key), under all four rules.
    #[test]
    fn folding_into_a_buffer_writes_what_fold_returns() {
        let mut keys: Vec<String> = (0..=0x10FFFFu32).filter_map(char::from_u32).map(String::from).collect();
        for k in ["", "Run", "RUN-up", "ıI", "ΐΐ", "Straße ẞ", "ΣΑΣ σας", "--!", "¿?", "Ꭰꭰ", "a\u{301}", "長 Word"]
        {
            keys.push(k.into());
        }
        let mut buf = Vec::new();
        for (case_sensitive, strip) in [(false, false), (false, true), (true, false), (true, true)] {
            for key in &keys {
                let want = fold(key, case_sensitive, strip);
                buf.clear();
                fold_into(key, case_sensitive, strip, &mut buf).unwrap();
                assert_eq!(buf, want.as_bytes(), "{key:?} {case_sensitive} {strip}");
                assert_eq!(fold_len(key, case_sensitive, strip), want.len(), "{key:?} {case_sensitive} {strip}");
            }
        }
    }

    /// The counting decoder gives the plain decoder's text, and counts every byte it replaced.
    #[test]
    fn lossy_bytes_are_counted() {
        let utf8 = Codec::Utf8;
        assert_eq!(utf8.decode_counted(b"caf\xC3\xA9"), ("café".into(), 0));
        assert_eq!(utf8.decode_counted(b"a\xFF\xFEb\xC3"), ("a\u{FFFD}\u{FFFD}b\u{FFFD}".into(), 3));
        let gbk = Codec::Legacy(encoding_rs::GB18030);
        assert_eq!(gbk.decode_counted(&[0xD6, 0xD0, 0xFF]).1, 1);
        let utf16 = Codec::Utf16Le;
        assert_eq!(utf16.decode_counted(&[0x41, 0x00, 0x00, 0xD8, 0x42, 0x00]).1, 2, "a lone surrogate");
        let mut seed = 7u32;
        for codec in [utf8, gbk, utf16, Codec::Legacy(encoding_rs::BIG5)] {
            for len in 0..300 {
                let bytes: Vec<u8> = (0..len)
                    .map(|_| {
                        seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                        (seed >> 16) as u8
                    })
                    .collect();
                let (text, lossy) = codec.decode_counted(&bytes);
                assert_eq!(text, codec.decode(&bytes));
                assert_eq!(lossy == 0, !text.contains('\u{FFFD}'));
            }
        }
    }

    /// 12 of freemdict's 3,394 MDX files declare Latin-1 (census, 2026-10-13).
    #[test]
    fn latin_1_is_read_as_the_web_reads_it() {
        for name in ["ISO8859-1", "iso-8859-1", "Latin1"] {
            let codec = Codec::for_file(Kind::Mdx, name).unwrap();
            assert_eq!(codec.decode(&[0x63, 0x61, 0x66, 0xE9]), "café", "{name}");
            // Where windows-1252 and strict Latin-1 differ: punctuation, not C1 control characters.
            assert_eq!(codec.decode(&[0x80, 0x91, 0x92]), "€‘’", "{name}");
        }
    }

    /// Case-insensitive keys compare under full case folding: a final sigma and a sharp s fold as their
    /// capitals do.
    #[test]
    fn case_folding_is_full_unicode_folding() {
        assert_eq!(fold("ΟΣ", false, true), fold("ος", false, true));
        assert_eq!(fold("Straße", false, true), fold("STRASSE", false, true));
        assert_eq!(fold("STRAẞE", false, true), fold("strasse", false, true));
        // Unicode keeps dotless ı apart from i; only Turkish tailoring joins them, and keys are not Turkish.
        assert_ne!(fold("ı", false, true), fold("i", false, true));
        assert_eq!(fold("İ", false, false), fold("i\u{307}", false, false));
        assert_ne!(fold("ΟΣ", true, true), fold("ος", true, true));
    }

    /// The ASCII path gives what the general one gives, for every ASCII character alone, in pairs, and in
    /// the shapes that matter: punctuation only, mixed case, already folded.
    #[test]
    fn ascii_folding_is_the_general_folding() {
        let general = |key: &str, cs: bool, strip: bool| {
            let cased = if cs { key.to_owned() } else { case_fold(key) };
            if !strip {
                return cased;
            }
            let stripped: String = cased.chars().filter(|c| c.is_alphanumeric()).collect();
            if stripped.is_empty() { cased } else { stripped }
        };
        let mut keys: Vec<String> = (0u8..128).map(|b| char::from(b).to_string()).collect();
        keys.extend(
            (0u8..128)
                .step_by(3)
                .flat_map(|a| (0u8..128).step_by(5).map(move |b| [char::from(a), char::from(b)].iter().collect())),
        );
        keys.extend(["", "...", "--", "Hello, World", "run", "RUN", "a--b--c", "@opal", "x y"].map(String::from));
        for key in &keys {
            for cs in [false, true] {
                for strip in [false, true] {
                    assert_eq!(fold(key, cs, strip), general(key, cs, strip), "{key:?} cs={cs} strip={strip}");
                }
            }
        }
    }

    #[test]
    fn an_unknown_encoding_is_refused_by_name() {
        let refused = Codec::for_file(Kind::Mdx, "EBCDIC");
        assert!(matches!(refused, Err(Error::Unsupported(Unsupported::Encoding(n))) if n == "EBCDIC"));
    }
}
