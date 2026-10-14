//! The header: a 4-byte big-endian length, one XML element, and its Adler-32, little-endian. The element is
//! UTF-16LE `<Dictionary>` or `<Library_Data>` up to 2.0, and UTF-8 `<ZDB>` in 3.0.

use crate::bytes::adler32;
use crate::{Error, FormatVersion, Header, Kind, Unsupported};

/// Parses the header's bytes, whose checksum has been read separately.
pub(crate) fn parse(bytes: &[u8], checksum: u32) -> Result<Header, Error> {
    if adler32(bytes) != checksum {
        return Err(Error::Malformed("the header's checksum does not match".into()));
    }
    // UTF-16 text starting with an ASCII `<` has a zero second byte; UTF-8 text never does.
    let text = if bytes.get(1) == Some(&0) {
        let (pairs, odd) = bytes.as_chunks::<2>();
        if !odd.is_empty() {
            return Err(Error::Malformed("the header is not whole UTF-16".into()));
        }
        let units: Vec<u16> = pairs.iter().map(|pair| u16::from_le_bytes(*pair)).collect();
        String::from_utf16(&units).map_err(|_| Error::Malformed("the header is not valid UTF-16".into()))?
    } else {
        String::from_utf8(bytes.to_vec()).map_err(|_| Error::Malformed("the header is not valid UTF-8".into()))?
    };
    let text = text.trim_end_matches(['\0', '\r', '\n', ' ']).trim_start();

    // The root element decides the layout, and with it the versions that may be declared.
    let (kind, layout_3, rest) = if let Some(rest) = element(text, "Dictionary") {
        (Kind::Mdx, false, rest)
    } else if let Some(rest) = element(text, "Library_Data") {
        (Kind::Mdd, false, rest)
    } else if let Some(rest) = element(text, "ZDB") {
        (Kind::Mdx, true, rest)
    } else {
        return Err(Error::Malformed("the header is neither a dictionary nor a resource library".into()));
    };
    let attributes = attributes(rest)?;
    let get = |name: &str| {
        attributes.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str()).unwrap_or("")
    };

    let version_text = get("GeneratedByEngineVersion").trim();
    let version = match (layout_3, version_text) {
        (false, "2.0") => FormatVersion::V2_0,
        (false, "1.2") => FormatVersion::V1_2,
        (true, "3.0") => FormatVersion::V3_0,
        (_, other) => return Err(Error::Unsupported(Unsupported::FormatVersion(other.to_owned()))),
    };
    let encrypted = match get("Encrypted").trim() {
        "" | "No" | "no" => 0,
        "Yes" | "yes" => 1,
        number => number
            .parse::<u8>()
            .map_err(|_| Error::Malformed(format!("the header's Encrypted value \"{number}\" is not understood")))?,
    };
    if encrypted & 1 != 0 {
        return Err(Error::Unsupported(Unsupported::RegistrationCode));
    }
    // Bit 2 is the key-index obfuscation the reader undoes; no other bit has a known meaning.
    if encrypted & !2 != 0 {
        return Err(Error::Unsupported(Unsupported::EncryptionFlags(encrypted)));
    }
    let yes = |name: &str| get(name).eq_ignore_ascii_case("yes");
    let strip_key = match get("StripKey") {
        v if v.eq_ignore_ascii_case("yes") => Some(true),
        v if v.eq_ignore_ascii_case("no") => Some(false),
        _ => None,
    };

    Ok(Header {
        kind,
        version,
        encrypted,
        title: get("Title").to_owned(),
        description: get("Description").to_owned(),
        key_case_sensitive: yes("KeyCaseSensitive"),
        strip_key,
        stylesheet: get("StyleSheet").to_owned(),
        attributes,
    })
}

/// The text after `<name`, where `text` opens an element of exactly that name.
pub(crate) fn element<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    let rest = text.strip_prefix('<')?.strip_prefix(name)?;
    (rest.starts_with(char::is_whitespace) || rest.starts_with("/>") || rest.starts_with('>')).then_some(rest)
}

/// `name="value"` pairs up to the element's end, with character references decoded. The element must be
/// closed, by `/>` or `>`, with nothing but whitespace after it; each attribute is set off by whitespace,
/// has a name, and appears once (names compared as lookups compare them, ignoring ASCII case).
pub(crate) fn attributes(mut rest: &str) -> Result<Vec<(String, String)>, Error> {
    let mut out: Vec<(String, String)> = Vec::new();
    loop {
        let trimmed = rest.trim_start();
        let separated = trimmed.len() < rest.len();
        rest = trimmed;
        if let Some(tail) = rest.strip_prefix("/>").or_else(|| rest.strip_prefix('>')) {
            if !tail.trim().is_empty() {
                return Err(Error::Malformed("an element has text after its end".into()));
            }
            return Ok(out);
        }
        if rest.is_empty() {
            return Err(Error::Malformed("an element is not closed".into()));
        }
        if !separated {
            return Err(Error::Malformed("two header attributes run together".into()));
        }
        // An XML name: a letter, `_` or `:` first, then letters, digits, `_`, `-`, `.` or `:`.
        let name_len =
            rest.find(|c: char| !(c.is_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'))).unwrap_or(rest.len());
        let (name, after) = rest.split_at(name_len);
        if !name.starts_with(|c: char| c.is_alphabetic() || matches!(c, '_' | ':')) {
            return Err(Error::Malformed("a header attribute's name does not start with a letter".into()));
        }
        let after = after.trim_start();
        let after = match after.strip_prefix('=') {
            Some(after) if !name.is_empty() => after.trim_start(),
            _ => return Err(Error::Malformed("a header attribute is not a name and a value".into())),
        };
        let quote = after.chars().next().filter(|c| *c == '"' || *c == '\'');
        let quote = quote.ok_or_else(|| Error::Malformed("a header attribute value is not quoted".into()))?;
        let body = after.get(1..).unwrap_or("");
        let end = body.find(quote).ok_or_else(|| Error::Malformed("a header attribute value is not closed".into()))?;
        let (value, tail) = body.split_at(end);
        if out.iter().any(|(k, _)| k.eq_ignore_ascii_case(name)) {
            return Err(Error::Malformed(format!("the header attribute {name} appears twice")));
        }
        if out.len() == crate::limits::HEADER_ATTRIBUTES {
            return Err(Error::Malformed(format!(
                "an element has more than the {} attributes allowed",
                crate::limits::HEADER_ATTRIBUTES
            )));
        }
        out.push((name.to_owned(), unescape(value)));
        rest = tail.get(1..).unwrap_or("");
    }
}

/// Where the reference that `after` starts with ends: the index of its `;`. The search stops at the next
/// `&`, so each stretch of text is searched once, and a run of bare ampersands costs linear time rather
/// than a search to the end of the text from every one of them.
fn reference_end(after: &str) -> Option<usize> {
    let end = after.get(1..)?.find([';', '&'])? + 1;
    after.get(end..)?.starts_with(';').then_some(end)
}

/// Decodes the five named references and numeric ones; anything else is kept as written.
fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(amp) = rest.find('&') {
        out.push_str(rest.get(..amp).unwrap_or(""));
        let after = rest.get(amp..).unwrap_or("");
        let decoded = reference_end(after).and_then(|semi| {
            let name = after.get(1..semi)?;
            let ch = match name {
                "lt" => Some('<'),
                "gt" => Some('>'),
                "amp" => Some('&'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                n if n.starts_with("#x") || n.starts_with("#X") => {
                    u32::from_str_radix(n.get(2..)?, 16).ok().and_then(char::from_u32)
                }
                n if n.starts_with('#') => n.get(1..)?.parse::<u32>().ok().and_then(char::from_u32),
                _ => None,
            }?;
            Some((ch, semi + 1))
        });
        match decoded {
            Some((ch, consumed)) => {
                out.push(ch);
                rest = after.get(consumed..).unwrap_or("");
            }
            None => {
                out.push('&');
                rest = after.get(1..).unwrap_or("");
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    fn parse_text(text: &str) -> Result<Header, Error> {
        let bytes = text.as_bytes();
        parse(bytes, adler32(bytes))
    }

    /// A header holds at most `limits::HEADER_ATTRIBUTES` attributes: past it, a megabyte of short ones would
    /// hold twenty times its size in entries and take minutes to check for repeats. The most in the owner's
    /// 359 files is 17.
    #[test]
    fn a_header_of_too_many_attributes_is_refused() {
        let with = |n: usize| {
            let names: String = (0..n).map(|i| format!(" a{i}=\"\"")).collect();
            format!("<ZDB GeneratedByEngineVersion=\"3.0\" UUID=\"u\"{names}/>")
        };
        assert!(parse_text(&with(crate::limits::HEADER_ATTRIBUTES - 2)).is_ok());
        let refused = parse_text(&with(crate::limits::HEADER_ATTRIBUTES - 1)).err().unwrap().to_string();
        assert!(refused.contains("attributes"), "{refused}");
    }

    fn parse_utf16(text: &str) -> Result<Header, Error> {
        let bytes: Vec<u8> = text.encode_utf16().flat_map(u16::to_le_bytes).collect();
        parse(&bytes, adler32(&bytes))
    }

    #[test]
    fn a_root_name_must_end_where_the_name_ends() {
        assert!(parse_text(r#"<ZDB GeneratedByEngineVersion="3.0"/>"#).is_ok());
        let refused = parse_text(r#"<ZDBX GeneratedByEngineVersion="3.0"/>"#);
        assert!(matches!(refused, Err(Error::Malformed(_))), "{refused:?}");
    }

    #[test]
    fn an_unclosed_element_or_trailing_text_is_malformed() {
        for text in [r#"<ZDB GeneratedByEngineVersion="3.0""#, r#"<ZDB GeneratedByEngineVersion="3.0"/> junk"#] {
            assert!(matches!(parse_text(text), Err(Error::Malformed(_))), "{text}");
        }
    }

    #[test]
    fn unknown_encryption_bits_are_refused_by_name() {
        let refused = parse_utf16(r#"<Dictionary GeneratedByEngineVersion="2.0" Encrypted="4"/>"#);
        assert!(matches!(refused, Err(Error::Unsupported(Unsupported::EncryptionFlags(4)))), "{refused:?}");
        assert!(parse_utf16(r#"<Dictionary GeneratedByEngineVersion="2.0" Encrypted="2"/>"#).is_ok());
    }

    /// A header may be 1 MiB. Decoding stays linear because a reference's end is never sought past the
    /// next `&`: a semicolon far away must not be found from every ampersand before it.
    #[test]
    fn a_reference_is_not_sought_past_the_next_ampersand() {
        assert_eq!(reference_end("&amp;rest"), Some(4));
        assert_eq!(reference_end("&amp"), None);
        let bare = format!("{};", "&".repeat(1000));
        assert_eq!(reference_end(&bare), None);
        assert_eq!(reference_end(bare.get(999..).unwrap()), Some(1));
    }

    #[test]
    fn attributes_need_names_and_separators() {
        for text in [
            r#"<ZDB GeneratedByEngineVersion="3.0" x/> junk="v"/>"#,
            r#"<ZDB GeneratedByEngineVersion="3.0"Title="t"/>"#,
            r#"<ZDB GeneratedByEngineVersion="3.0" ="t"/>"#,
            r#"<ZDB GeneratedByEngineVersion="3.0" 1bad="t"/>"#,
            r#"<ZDB GeneratedByEngineVersion="3.0" -="t"/>"#,
        ] {
            assert!(matches!(parse_text(text), Err(Error::Malformed(_))), "{text}");
        }
    }

    #[test]
    fn a_repeated_attribute_is_malformed() {
        let refused = parse_utf16(r#"<Dictionary GeneratedByEngineVersion="2.0" Encrypted="0" encrypted="1"/>"#);
        assert!(matches!(refused, Err(Error::Malformed(_))), "{refused:?}");
    }
}
