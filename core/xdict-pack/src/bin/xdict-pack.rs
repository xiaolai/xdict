//! `xdict-pack build --raw-dir RAW [--output OUT] [--manifest MANIFEST] [--notice-dir DIR]`
//!
//! Builds the word pack, its notices sidecar and a report, and prints the report. `xdict-pack verify --raw-dir RAW`
//! checks every raw file against its pinned size and SHA-256 and writes nothing.

use std::path::PathBuf;
use std::process::ExitCode;

use xdict_pack::{BuildOptions, Control, Event, PackError, build, manifest, refuse_inside_repository};

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("xdict-pack: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), PackError> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_default();
    let mut raw_dir: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;
    let mut manifest_path: Option<PathBuf> = None;
    let mut notice_dir: Option<PathBuf> = None;
    while let Some(flag) = args.next() {
        let mut value = || -> Result<PathBuf, PackError> {
            args.next()
                .map(PathBuf::from)
                .ok_or_else(|| PackError::new(xdict_pack::PackErrorKind::Malformed, format!("{flag} needs a path")))
        };
        match flag.as_str() {
            "--raw-dir" => raw_dir = Some(value()?),
            "--output" => output = Some(value()?),
            "--manifest" => manifest_path = Some(value()?),
            "--notice-dir" => notice_dir = Some(value()?),
            other => {
                return Err(PackError::new(
                    xdict_pack::PackErrorKind::Malformed,
                    format!("unknown argument '{other}'"),
                ));
            }
        }
    }
    let raw_dir =
        raw_dir.ok_or_else(|| PackError::new(xdict_pack::PackErrorKind::Malformed, "xdict-pack needs --raw-dir"))?;
    match command.as_str() {
        "verify" => {
            let manifest_path = manifest_path.unwrap_or_else(default_manifest);
            for entry in manifest::read_manifest(&manifest_path)? {
                if entry.is_kaikki() {
                    continue;
                }
                let path = entry.path(&raw_dir);
                manifest::verify_file(&path, &entry.sha256, Some(entry.bytes), &entry.id)?;
                println!("ok {} {}", entry.id, entry.sha256);
            }
            Ok(())
        }
        "build" => {
            let output = output.unwrap_or_else(|| {
                let parent = raw_dir.parent().unwrap_or(&raw_dir).to_path_buf();
                parent.join("pack").join(xdict_pack::limits::PACK_NAME)
            });
            let manifest_path = manifest_path.unwrap_or_else(default_manifest);
            refuse_inside_repository(&output, &std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))?;
            let mut options = BuildOptions::new(&raw_dir, &output, &manifest_path);
            options.notice_dir = notice_dir;
            let report = build(&options, &mut |event| {
                match event {
                    Event::SourceStarted { id, bytes } => eprintln!("reading {id} ({bytes} bytes)"),
                    Event::SourceFinished { id } => eprintln!("read {id}"),
                    Event::Writing => eprintln!("writing the pack"),
                }
                Control::Continue
            })?;
            print!("{}", report.to_json());
            Ok(())
        }
        _ => Err(PackError::new(
            xdict_pack::PackErrorKind::Malformed,
            "usage: xdict-pack <verify|build> --raw-dir RAW [--output OUT] [--manifest MANIFEST]",
        )),
    }
}

/// The manifest that ships beside the builder: `core/xdict-core/tools/word_lexicon_sources.json` in the repository.
fn default_manifest() -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.pop();
    path.push("xdict-core");
    path.push("tools");
    path.push("word_lexicon_sources.json");
    path
}
