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

    /// What [`Self::decode_exact`] holds to decode `bytes`, known before it does, so a key can be weighed first
    /// (`keys.rs`): the UTF-8 text exactly (each bad sequence becomes U+FFFD, three bytes), or the most the
    /// decoder says its text can take. `TooLarge` past `usize`.
    pub(crate) fn decoded_capacity(self, bytes: &[u8]) -> Result<usize, Error> {
        let encoding = match self {
            Self::Utf8 => {
                let mut lengths =
                    bytes.utf8_chunks().map(|c| c.valid().len() + if c.invalid().is_empty() { 0 } else { 3 });
                return lengths.try_fold(0usize, usize::checked_add).ok_or_else(too_long);
            }
            Self::Utf16Le => encoding_rs::UTF_16LE,
            Self::Legacy(encoding) => encoding,
        };
        encoding.new_decoder_without_bom_handling().max_utf8_buffer_length(bytes.len()).ok_or_else(too_long)
    }

    /// [`Self::decode`]'s text, made in exactly `capacity` bytes ([`Self::decoded_capacity`]) reserved fallibly
    /// and never grown: std and encoding_rs would grow a string by doubling, holding up to three times the text
    /// while they do.
    pub(crate) fn decode_exact(self, bytes: &[u8], capacity: usize) -> Result<String, Error> {
        let mut text = String::new();
        text.try_reserve_exact(capacity).map_err(crate::out_of_memory)?;
        let encoding = match self {
            Self::Utf8 => {
                // What `String::from_utf8_lossy` does, into the reserved text.
                for chunk in bytes.utf8_chunks() {
                    text.push_str(chunk.valid());
                    if !chunk.invalid().is_empty() {
                        text.push('\u{FFFD}');
                    }
                }
                return Ok(text);
            }
            Self::Utf16Le => encoding_rs::UTF_16LE,
            Self::Legacy(encoding) => encoding,
        };
        // Into the spare capacity alone: with the decoder's most reserved, it reads every byte in one call.
        let (result, read, _) = encoding.new_decoder_without_bom_handling().decode_to_string(bytes, &mut text, true);
        if result != encoding_rs::CoderResult::InputEmpty || read != bytes.len() {
            return Err(Error::Malformed("a key does not decode within the room its decoder asked for".into()));
        }
        Ok(text)
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
    /// 600 KB entry should not hide the other 599,999. Through std and encoding_rs alone: what
    /// [`Self::decode_exact`] and [`Self::decode_counted`] are checked against.
    #[cfg(test)]
    pub(crate) fn decode(self, bytes: &[u8]) -> String {
        match self {
            Self::Utf8 => String::from_utf8_lossy(bytes).into_owned(),
            Self::Utf16Le => encoding_rs::UTF_16LE.decode_without_bom_handling(bytes).0.into_owned(),
            Self::Legacy(encoding) => encoding.decode_without_bom_handling(bytes).0.into_owned(),
        }
    }
}

/// The most folding lengthens a key, in UTF-8 bytes per byte: ΐ (2 bytes) folds to 6. Measured over every
/// scalar value under all four rules by a test; an index build counts it (`keys.rs`).
pub(crate) const FOLD_GROWTH: u64 = 3;

fn too_long() -> Error {
    Error::TooLarge("a key is too long to decode".into())
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

    /// [`FOLD_GROWTH`] is measured: no scalar value folds, under any of the four rules, to more than that many
    /// times its UTF-8 length, and one folds to exactly that (ΐ, 2 bytes to 6). Folding goes character by
    /// character, so a key's folding is at most the sum of its characters'.
    #[test]
    fn fold_growth_is_measured_over_every_scalar_value() {
        let mut most = (0u64, 1u64);
        for c in (0..=0x10FFFFu32).filter_map(char::from_u32) {
            let key = c.to_string();
            for (case_sensitive, strip) in [(false, false), (false, true), (true, false), (true, true)] {
                let (from, to) = (key.len() as u64, fold_len(&key, case_sensitive, strip) as u64);
                assert!(to <= FOLD_GROWTH * from, "U+{:04X}: {from} bytes to {to}", c as u32);
                if to * most.1 > most.0 * from {
                    most = (to, from);
                }
            }
        }
        assert_eq!(most.0.div_ceil(most.1), FOLD_GROWTH, "the constant is not tight");
    }

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

    /// [`Codec::decode_exact`] gives [`Codec::decode`]'s text and holds nothing but the capacity
    /// [`Codec::decoded_capacity`] said, by the allocator: for every codec, the bytes that grow most under each
    /// (bad bytes, windows-1252's 0x80–0x9F, four-byte GB18030 and Big5 HKSCS, UTF-16 astral and lone surrogates,
    /// cut sequences) and random bytes, at every length to 300 and either side of each power of two to 8192,
    /// where a string grown by doubling would show it. 3,000 bad Big5 bytes held 24,576 decoded by `decode`.
    #[test]
    fn decode_holds_what_it_reserved_by_the_allocator() {
        let codecs = [
            ("UTF-8", Codec::Utf8),
            ("UTF-16LE", Codec::Utf16Le),
            ("GB18030", Codec::Legacy(encoding_rs::GB18030)),
            ("Big5", Codec::Legacy(encoding_rs::BIG5)),
            ("windows-1252", Codec::Legacy(encoding_rs::WINDOWS_1252)),
        ];
        let mut seed = 7u32;
        let random: Vec<u8> = (0..8192)
            .map(|_| {
                seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                (seed >> 16) as u8
            })
            .collect();
        let patterns: [&[u8]; 14] = [
            &[0x80],
            &[0xFF],
            &[0xE9],
            &[0xC3, 0xA9],
            &[0xF0, 0x9F, 0x98, 0x80],
            &[0xE2, 0x82],
            &[0x90, 0x30, 0x81, 0x30],
            &[0x81, 0x30, 0x81, 0x30],
            &[0x87, 0x40],
            &[0x00, 0xD8],
            &[0x3D, 0xD8, 0x00, 0xDE],
            &[0x2D, 0x4E],
            &[0x41, 0x80],
            &random,
        ];
        let powers = (2..=13).flat_map(|k| [(1 << k) - 1, 1 << k, (1 << k) + 1]);
        let lengths: Vec<usize> = (0..=300).chain(powers).chain([3000]).collect();
        for (name, codec) in codecs {
            for (p, pattern) in patterns.iter().enumerate() {
                for &len in &lengths {
                    let bytes: Vec<u8> = pattern.iter().copied().cycle().take(len).collect();
                    let capacity = codec.decoded_capacity(&bytes).unwrap();
                    let mut text = None;
                    let held = allocation_counter::measure(|| text = Some(codec.decode_exact(&bytes, capacity)));
                    let text = text.unwrap().unwrap();
                    let at = format!("{name}, pattern {p}, {len} bytes");
                    assert_eq!(text, codec.decode(&bytes), "{at}");
                    assert_eq!(text.capacity(), capacity, "{at}: the text grew");
                    assert!(held.bytes_max <= capacity as u64, "{at}: held {}, reserved {capacity}", held.bytes_max);
                }
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
