//! **Which real-file corpus a test reads** (audit 2026-11-05, G4): a corpus test that finds no corpus says "not
//! measured" and passes, which a gate cannot tell from a measurement. With `XDICT_CORPUS_REQUIRED=1` an unset or empty
//! variable is a failure, and a folder the variable names that does not exist is a failure always.

use std::ffi::OsString;
use std::path::PathBuf;

/// Set to `1` by a run whose green must mean the corpus was read.
pub const REQUIRED: &str = "XDICT_CORPUS_REQUIRED";

/// The value of `var` when it names folders that exist; `Ok(None)` when it is unset and no measurement is required.
pub fn wanted(var: &str) -> Result<Option<OsString>, String> {
    decide(var, std::env::var_os(var), std::env::var_os(REQUIRED).is_some_and(|value| value == "1"))
}

/// [`wanted`], with the environment passed in.
pub fn decide(var: &str, value: Option<OsString>, required: bool) -> Result<Option<OsString>, String> {
    let folders: Vec<PathBuf> = value
        .as_ref()
        .map(|value| std::env::split_paths(value).filter(|path| !path.as_os_str().is_empty()).collect())
        .unwrap_or_default();
    if folders.is_empty() {
        return if required {
            Err(format!("{var} names no folder, and {REQUIRED}=1 asks for a measurement"))
        } else {
            Ok(None)
        };
    }
    if let Some(missing) = folders.iter().find(|path| !path.is_dir()) {
        return Err(format!("{var} names {}, which is not a folder", missing.display()));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_required_measurement_without_a_corpus_fails_and_an_optional_one_is_skipped() {
        assert_eq!(decide("XDICT_MDX_CORPUS", None, false), Ok(None));
        assert!(decide("XDICT_MDX_CORPUS", None, true).is_err_and(|why| why.contains("XDICT_MDX_CORPUS")));
        assert!(decide("XDICT_MDX_CORPUS", Some(OsString::new()), true).is_err());
        let here = std::env::temp_dir().into_os_string();
        assert_eq!(decide("XDICT_MDX_CORPUS", Some(here.clone()), true), Ok(Some(here)));
        let gone = std::env::temp_dir().join("xdict-no-such-corpus-folder").into_os_string();
        assert!(decide("XDICT_MDX_CORPUS", Some(gone), false).is_err_and(|why| why.contains("not a folder")));
    }
}
