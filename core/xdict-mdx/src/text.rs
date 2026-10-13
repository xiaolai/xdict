//! The text encodings a file may declare, and the folding a lookup applies.

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
pub(crate) fn fold(key: &str, case_sensitive: bool, strip: bool) -> String {
    let cased = if case_sensitive { key.to_owned() } else { case_fold(key) };
    if !strip {
        return cased;
    }
    let stripped: String = cased.chars().filter(|c| c.is_alphanumeric()).collect();
    if stripped.is_empty() { cased } else { stripped }
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

    #[test]
    fn an_unknown_encoding_is_refused_by_name() {
        let refused = Codec::for_file(Kind::Mdx, "EBCDIC");
        assert!(matches!(refused, Err(Error::Unsupported(Unsupported::Encoding(n))) if n == "EBCDIC"));
    }
}
