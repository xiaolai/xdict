//! The conformance fixtures (`conformance/` at the repository's top) are descriptions, not files: each
//! dictionary is a JSON list of entries, written into `.mdx` and `.mdd` files by `xdict-mdx-writer` when a
//! suite runs. So no binary enters the repository, and no dictionary content: the text is our own.

use std::path::{Path, PathBuf};

use serde_json::Value;
use xdict_mdx_writer::{self as writer, Compression, Defect, Entry, Kind, Spec, TextEncoding, Version};

/// The repository's `conformance/fixtures`.
pub fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../conformance/fixtures")
}

/// The fixtures: every folder of [`fixtures`] holding a `dictionary.json`, sorted.
pub fn fixture_names() -> Result<Vec<String>, Error> {
    let mut names = Vec::new();
    for entry in std::fs::read_dir(fixtures()).map_err(bad)? {
        let path = entry.map_err(bad)?.path();
        if path.join("dictionary.json").is_file()
            && let Some(name) = path.file_name().and_then(|n| n.to_str())
        {
            names.push(name.to_owned());
        }
    }
    names.sort();
    Ok(names)
}

#[derive(Debug)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

fn bad(what: impl std::fmt::Display) -> Error {
    Error(what.to_string())
}

/// Writes the dictionary a fixture's `dictionary.json` describes into `out`: its MDX, its MDD volumes and
/// its sidecars, under the names the description gives.
pub fn write_fixture(fixture: &Path, out: &Path) -> Result<(), Error> {
    let text = std::fs::read_to_string(fixture.join("dictionary.json")).map_err(bad)?;
    let description: Value = serde_json::from_str(&text).map_err(bad)?;
    std::fs::create_dir_all(out).map_err(bad)?;

    let mdx = field(&description, "mdx")?;
    let spec = Spec { title: string(field(mdx, "title")?)?.into(), ..Spec::mdx() };
    if let Some(variants) = description.get("variants") {
        return write_variants(&spec, field(mdx, "entries")?, array(variants)?, out);
    }
    write_file(&spec, field(mdx, "entries")?, &out.join(string(field(mdx, "name")?)?))?;
    for volume in array(field(&description, "mdd")?)? {
        write_file(&Spec::mdd(), field(volume, "entries")?, &out.join(string(field(volume, "name")?)?))?;
    }
    for sidecar in array(field(&description, "sidecars")?)? {
        let name = string(field(sidecar, "name")?)?;
        std::fs::write(out.join(name), string(field(sidecar, "text")?)?).map_err(bad)?;
    }
    // The MDX again with a deliberate fault each, for the errors a binding must carry.
    for file in description.get("defective").map(array).transpose()?.into_iter().flatten() {
        let defect = match string(field(file, "defect")?)? {
            "unknownFormatVersion" => Defect::UnknownFormatVersion,
            "headerChecksum" => Defect::HeaderChecksum,
            other => return Err(bad(format!("no defect {other}"))),
        };
        let faulty = Spec { defect: Some(defect), ..spec.clone() };
        write_file(&faulty, field(mdx, "entries")?, &out.join(string(field(file, "name")?)?))?;
    }
    Ok(())
}

/// A fixture written once per variant (`<name>.mdx`), each with its own `$word` and `$gloss`, and
/// `variants.json`, which the suites read: each variant's name, word, gloss and format version.
fn write_variants(base: &Spec, entries: &Value, variants: &[Value], out: &Path) -> Result<(), Error> {
    let mut written = Vec::new();
    for variant in variants {
        let name = string(field(variant, "name")?)?;
        let version = match string(field(variant, "version")?)? {
            "1.2" => Version::V1_2,
            "2.0" => Version::V2_0,
            "3.0" => Version::V3_0,
            other => return Err(bad(format!("{name}: no version {other}"))),
        };
        let compression = match string(field(variant, "compression")?)? {
            "none" => Compression::None,
            "zlib" => Compression::Zlib,
            "lzo" => Compression::Lzo,
            other => return Err(bad(format!("{name}: no compression {other}"))),
        };
        let encoding = match string(field(variant, "encoding")?)? {
            "utf8" => TextEncoding::Utf8,
            "utf16" => TextEncoding::Utf16,
            "gbk" => TextEncoding::Gbk,
            "big5" => TextEncoding::Big5,
            "latin1" => TextEncoding::Latin1,
            other => return Err(bad(format!("{name}: no encoding {other}"))),
        };
        let (word, gloss) = (string(field(variant, "word")?)?, string(field(variant, "gloss")?)?);
        // The suites substitute these into expected.json's text, so they must need no escaping in JSON; and they
        // substitute one placeholder after another, so neither may hold a `$` that a later one would replace.
        if [word, gloss].iter().any(|t| t.chars().any(|c| c == '"' || c == '\\' || c.is_control())) {
            return Err(bad(format!("{name}: a word or gloss needs escaping in JSON")));
        }
        if [word, gloss].iter().any(|t| t.contains('$')) {
            return Err(bad(format!(
                "{name}: a word or gloss holds a `$`, which the suites would read as a placeholder"
            )));
        }
        let text = entries.to_string().replace("$word", word).replace("$gloss", gloss);
        let spec = Spec {
            version,
            compression,
            kind: Kind::Mdx(encoding),
            obfuscate_key_index: version == Version::V2_0,
            ..base.clone()
        };
        write_file(&spec, &serde_json::from_str(&text).map_err(bad)?, &out.join(format!("{name}.mdx")))?;
        written.push(
            serde_json::json!({ "name": name, "word": word, "gloss": gloss, "version": field(variant, "version")? }),
        );
    }
    std::fs::write(out.join("variants.json"), Value::Array(written).to_string()).map_err(bad)
}

fn write_file(spec: &Spec, entries: &Value, path: &Path) -> Result<(), Error> {
    let entries = array(entries)?
        .iter()
        .map(|pair| match array(pair)?.as_slice() {
            [key, record] => Ok(Entry::text(string(key)?, string(record)?)),
            _ => Err(bad(format!("an entry is a key and a record, not {pair}"))),
        })
        .collect::<Result<Vec<_>, Error>>()?;
    let bytes = writer::write(spec, &entries).map_err(bad)?;
    std::fs::write(path, bytes).map_err(bad)
}

fn field<'a>(value: &'a Value, key: &str) -> Result<&'a Value, Error> {
    value.get(key).ok_or_else(|| bad(format!("{key:?} is missing from {value}")))
}

fn string(value: &Value) -> Result<&str, Error> {
    value.as_str().ok_or_else(|| bad(format!("expected a string, found {value}")))
}

fn array(value: &Value) -> Result<&Vec<Value>, Error> {
    value.as_array().ok_or_else(|| bad(format!("expected a list, found {value}")))
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    /// The suites put each variant's word and gloss into expected.json one placeholder after another, so a word
    /// or gloss holding a placeholder would be replaced again: such a variant is refused, not written.
    #[test]
    fn a_word_or_gloss_holding_a_placeholder_is_refused() {
        let out = std::env::temp_dir().join(format!("xdict-conformance-placeholder-{}", std::process::id()));
        std::fs::create_dir_all(&out).unwrap();
        let entries = serde_json::json!([["$word", "$gloss"]]);
        for (word, gloss) in [("$gloss", "a gloss"), ("run", "$version"), ("$word", "a gloss")] {
            let variant = serde_json::json!({
                "name": "v", "version": "2.0", "compression": "zlib", "encoding": "utf8", "word": word, "gloss": gloss,
            });
            assert!(write_variants(&Spec::mdx(), &entries, &[variant], &out).is_err(), "{word:?} {gloss:?}");
        }
        let fine = serde_json::json!({
            "name": "v", "version": "2.0", "compression": "zlib", "encoding": "utf8", "word": "run", "gloss": "to go",
        });
        write_variants(&Spec::mdx(), &entries, &[fine], &out).unwrap();
        std::fs::remove_dir_all(&out).unwrap();
    }
}
