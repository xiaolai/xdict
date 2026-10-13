//! `conformance-fixtures <out-dir>`: writes every fixture's files (each folder of `conformance/fixtures`
//! with a `dictionary.json`) into `<out-dir>/<fixture>/`, for the bindings' suites to read.

use std::process::ExitCode;

fn main() -> ExitCode {
    let Some(out) = std::env::args_os().nth(1) else {
        eprintln!("usage: conformance-fixtures <out-dir>");
        return ExitCode::FAILURE;
    };
    let out = std::path::PathBuf::from(out);
    let fixtures = match xdict_conformance::fixture_names() {
        Ok(names) if !names.is_empty() => names,
        Ok(_) => {
            eprintln!("no fixtures in {}", xdict_conformance::fixtures().display());
            return ExitCode::FAILURE;
        }
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    for name in fixtures {
        if let Err(e) = xdict_conformance::write_fixture(&xdict_conformance::fixtures().join(&name), &out.join(&name)) {
            eprintln!("{name}: {e}");
            return ExitCode::FAILURE;
        }
    }
    ExitCode::SUCCESS
}
