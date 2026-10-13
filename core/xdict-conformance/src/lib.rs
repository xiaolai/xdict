//! The conformance fixtures (`conformance/` at the repository's top) are descriptions, not files: each
//! dictionary is a JSON list of entries, written into `.mdx` and `.mdd` files by `xdict-mdx-writer` when a
//! suite runs. So no binary enters the repository, and no dictionary content: the text is our own.

use std::path::{Path, PathBuf};

use serde_json::Value;
use xdict_mdx_writer::{self as writer, Entry, Spec};

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
    write_file(&spec, field(mdx, "entries")?, &out.join(string(field(mdx, "name")?)?))?;
    for volume in array(field(&description, "mdd")?)? {
        write_file(&Spec::mdd(), field(volume, "entries")?, &out.join(string(field(volume, "name")?)?))?;
    }
    for sidecar in array(field(&description, "sidecars")?)? {
        let name = string(field(sidecar, "name")?)?;
        std::fs::write(out.join(name), string(field(sidecar, "text")?)?).map_err(bad)?;
    }
    Ok(())
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
