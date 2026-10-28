//! The build: verify every raw file, parse every provider, write the pack, its notices sidecar and a report.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use sha2::{Digest, Sha256};

use crate::builder::PackBuilder;
use crate::error::{PackError, PackErrorKind, PackResult};
use crate::json::{self, Value};
use crate::limits::{MAX_DEPTH, PACK_NAME};
use crate::manifest::{Notice, Source, read_manifest, read_notices, verify_open};
use crate::notices::notices_text;
use crate::record::header_source;
use crate::skips::Skips;

/// What a build is asked to do: the raw downloads, where the pack goes, and the manifest that pins them.
#[derive(Debug, Clone)]
pub struct BuildOptions {
    /// The directory holding the raw downloads.
    pub raw_dir: PathBuf,
    /// The pack's path, outside Git.
    pub output: PathBuf,
    /// The pinned-sources manifest.
    pub manifest: PathBuf,
    /// Where the notice files sit; the raw directory when unset.
    pub notice_dir: Option<PathBuf>,
    /// A flag another thread may raise to stop the build, which then writes nothing.
    pub cancel: Option<std::sync::Arc<AtomicBool>>,
}

impl BuildOptions {
    /// The options for a build of `manifest`'s sources in `raw_dir`, writing to `output`.
    pub fn new(raw_dir: impl Into<PathBuf>, output: impl Into<PathBuf>, manifest: impl Into<PathBuf>) -> Self {
        Self {
            raw_dir: raw_dir.into(),
            output: output.into(),
            manifest: manifest.into(),
            notice_dir: None,
            cancel: None,
        }
    }

    /// Cancellable by another thread raising `flag`.
    pub fn with_cancel(mut self, flag: std::sync::Arc<AtomicBool>) -> Self {
        self.cancel = Some(flag);
        self
    }

    /// Where the notice files sit.
    pub fn notices_from(&self) -> &Path {
        self.notice_dir.as_deref().unwrap_or(&self.raw_dir)
    }
}

/// What a build tells its caller as it works.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event<'a> {
    /// A source's raw file has been verified and its parse is about to begin.
    SourceStarted { id: &'a str, bytes: u64 },
    /// A source's records are all in.
    SourceFinished { id: &'a str },
    /// The records are collected and the pack is being written.
    Writing,
}

/// What the caller wants the build to do next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Control {
    /// Keep going.
    Continue,
    /// Stop, writing nothing.
    Cancel,
}

/// A finished build: where its files went, what they hold, and the report it wrote.
#[derive(Debug, Clone)]
pub struct Report {
    /// The pack's path, as it was given.
    pub pack: PathBuf,
    /// The pack's SHA-256.
    pub pack_sha256: String,
    /// The notices sidecar's path.
    pub notices: PathBuf,
    /// The notices sidecar's SHA-256.
    pub notices_sha256: String,
    /// The report's path.
    pub report: PathBuf,
    /// The report's text, as written.
    pub report_text: String,
    /// How many distinct records of each type the pack holds.
    pub records: BTreeMap<&'static str, usize>,
    /// How many records each source's parse produced, by type.
    pub parsed_by_source: BTreeMap<String, BTreeMap<String, u64>>,
    /// The records left out for a loader bound, by reason.
    pub rejected: BTreeMap<String, u64>,
    /// The source rows skipped, by reason.
    pub skipped: BTreeMap<String, u64>,
    /// The first metadata samples of each skipped reason.
    pub skipped_samples: BTreeMap<String, Vec<Value>>,
    /// The header's source ids, in the order the pack lists them.
    pub source_ids: Vec<String>,
}

impl Report {
    /// The report as the JSON document a build writes.
    pub fn to_json(&self) -> String {
        json::report(&Value::obj(vec![
            ("pack", Value::str(self.pack.display().to_string())),
            ("packSha256", Value::str(self.pack_sha256.clone())),
            ("notices", Value::str(self.notices.display().to_string())),
            ("noticesSha256", Value::str(self.notices_sha256.clone())),
            (
                "records",
                Value::Obj(
                    self.records.iter().map(|(kind, count)| ((*kind).to_string(), Value::Int(*count as u64))).collect(),
                ),
            ),
            (
                "parsedBySource",
                Value::Obj(
                    self.parsed_by_source
                        .iter()
                        .map(|(source, types)| {
                            (
                                source.clone(),
                                Value::Obj(
                                    types.iter().map(|(kind, count)| (kind.clone(), Value::Int(*count))).collect(),
                                ),
                            )
                        })
                        .collect(),
                ),
            ),
            (
                "rejected",
                Value::Obj(self.rejected.iter().map(|(reason, count)| (reason.clone(), Value::Int(*count))).collect()),
            ),
            (
                "skipped",
                Value::Obj(self.skipped.iter().map(|(reason, count)| (reason.clone(), Value::Int(*count))).collect()),
            ),
            (
                "skippedSamples",
                Value::Obj(
                    self.skipped_samples
                        .iter()
                        .map(|(reason, samples)| (reason.clone(), Value::Arr(samples.clone())))
                        .collect(),
                ),
            ),
            ("sources", Value::Arr(self.source_ids.iter().map(|id| Value::str(id.clone())).collect())),
        ]))
    }
}

/// Verify every raw file, parse every provider, write the pack, its notices sidecar and a build report.
pub fn build(options: &BuildOptions, progress: &mut dyn FnMut(Event<'_>) -> Control) -> PackResult<Report> {
    let own = AtomicBool::new(false);
    let cancel = options.cancel.as_deref().unwrap_or(&own);
    let entries = read_manifest(&options.manifest)?;
    let mut jobs: Vec<(Source, std::fs::File)> = Vec::new();
    for entry in entries {
        if entry.is_kaikki() {
            continue;
        }
        let path = entry.path(&options.raw_dir);
        let file = verify_open(&path, &entry.sha256, Some(entry.bytes), &entry.id)?;
        jobs.push((entry, file));
    }
    let mut notices: Vec<(crate::record::HeaderSource, Vec<Notice>)> = Vec::with_capacity(jobs.len());
    for (entry, _) in &jobs {
        notices.push((header_source(entry)?, read_notices(entry, options.notices_from())?));
    }
    let sources: Vec<Source> = jobs.iter().map(|(entry, _)| entry.clone()).collect();
    let mut builder = PackBuilder::new(&sources, false)?;
    let mut skipped: BTreeMap<String, u64> = BTreeMap::new();
    let mut samples: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    let mut by_source: BTreeMap<String, BTreeMap<String, u64>> = BTreeMap::new();
    for (entry, file) in jobs {
        let id = &entry.id;
        if progress(Event::SourceStarted { id: id.as_str(), bytes: entry.bytes }) == Control::Cancel {
            return Err(cancelled());
        }
        let mut tally: BTreeMap<String, u64> = BTreeMap::new();
        {
            let mut emit = |record: crate::record::RawRecord| {
                if cancel.load(Ordering::Relaxed) {
                    return Err(cancelled());
                }
                let kind = record.kind().unwrap_or("").to_string();
                builder.add(&record, id)?;
                *tally.entry(kind).or_insert(0) += 1;
                Ok(())
            };
            let source_skips = parse_provider(&entry, file, cancel, &mut emit)?;
            for (reason, count) in source_skips.counts() {
                skipped.insert(format!("{id}: {reason}"), *count);
            }
            for (reason, kept) in source_skips.samples() {
                samples.insert(format!("{id}: {reason}"), kept.clone());
            }
        }
        by_source.insert(id.clone(), tally);
        if progress(Event::SourceFinished { id: id.as_str() }) == Control::Cancel {
            return Err(cancelled());
        }
    }
    if progress(Event::Writing) == Control::Cancel {
        return Err(cancelled());
    }
    // **Everything is prepared before anything replaces a file**: a build that fails here leaves the pack already on
    // disk exactly as it was, rather than a new pack with yesterday's notices beside it.
    let lines = builder.pack_lines()?;
    let mut pack_bytes = String::with_capacity(lines.iter().map(|line| line.len() + 1).sum());
    for line in &lines {
        pack_bytes.push_str(line);
        pack_bytes.push('\n');
    }
    let pack_sha = json::hex(&Sha256::digest(pack_bytes.as_bytes()));
    let stem = options.output.file_stem().and_then(|stem| stem.to_str()).unwrap_or("xdict-words-en");
    let sidecar = options.output.with_file_name(format!("{stem}.notices.md"));
    let notice_text = notices_text(
        options.output.file_name().and_then(|name| name.to_str()).unwrap_or(PACK_NAME),
        &pack_sha,
        &notices,
    );
    let notice_bytes = notice_text.as_bytes();
    let report_path = options.output.with_file_name(format!("{stem}.report.json"));
    let mut report = Report {
        pack: options.output.clone(),
        pack_sha256: pack_sha,
        notices: sidecar.clone(),
        notices_sha256: json::hex(&Sha256::digest(notice_bytes)),
        report: report_path.clone(),
        report_text: String::new(),
        records: builder.counts(),
        parsed_by_source: by_source,
        rejected: builder.rejected().clone(),
        skipped,
        skipped_samples: samples,
        source_ids: builder.sources().iter().map(|source| source.id().to_string()).collect(),
    };
    report.report_text = report.to_json();
    let staged_pack = stage(&options.output, pack_bytes.as_bytes())?;
    let staged_notices = stage(&sidecar, notice_bytes)?;
    let staged_report = stage(&report_path, report.report_text.as_bytes())?;
    // **Published only now**, each file a rename of one already written whole.
    // **The pack is published last**: a failure part-way leaves the pack already on disk untouched rather than a new
    // pack standing beside yesterday's notices.
    publish(&staged_notices, &sidecar)?;
    publish(&staged_report, &report_path)?;
    publish(&staged_pack, &options.output)?;
    Ok(report)
}

fn cancelled() -> PackError {
    PackError::new(PackErrorKind::Cancelled, "the build was cancelled")
}

/// Parses one source, handing each record to `emit`, and returns what it skipped.
fn parse_provider(
    entry: &Source,
    file: std::fs::File,
    cancel: &AtomicBool,
    emit: &mut dyn FnMut(crate::record::RawRecord) -> PackResult<()>,
) -> PackResult<Skips> {
    let id = entry.id.as_str();
    match entry.provider.as_str() {
        "cmudict" => {
            crate::cmudict::parse_cmudict(file, id, emit)?;
            Ok(Skips::new())
        }
        "oewn" => {
            let docs = crate::oewn::read_oewn_zip(file, id)?;
            crate::oewn::parse_oewn_entries(&docs, id, emit)?;
            Ok(Skips::new())
        }
        "etymology-db" => {
            let reader = crate::sources::gzip_reader(file);
            let graph = crate::etymology::parse_etymology_csv(reader, id, cancel)?;
            crate::etymology::etymology_records(&graph, id, MAX_DEPTH, emit)?;
            Ok(graph.skips().clone())
        }
        "morphynet-inflection" | "morphynet-derivation" => {
            let mut unknown: BTreeMap<String, u64> = BTreeMap::new();
            let mut skips = Skips::new();
            if entry.provider == "morphynet-inflection" {
                crate::morphynet::parse_morphynet_inflection(file, id, &mut unknown, &mut skips, emit)?;
            } else {
                crate::morphynet::parse_morphynet_derivation(file, id, &mut unknown, &mut skips, emit)?;
            }
            if !unknown.is_empty() {
                let listed =
                    unknown.iter().map(|(name, count)| format!("{name} ({count})")).collect::<Vec<_>>().join(", ");
                return Err(PackError::at_source(PackErrorKind::Version, id, format!("unknown codes: {listed}")));
            }
            Ok(skips)
        }
        other => Err(PackError::at_source(PackErrorKind::Malformed, id, format!("unknown provider '{other}'"))),
    }
}

/// Writes `lines` newline-terminated as UTF-8 through a temporary file and a rename; returns the SHA-256.
pub fn write_pack(path: &Path, lines: &[String]) -> PackResult<String> {
    let mut data = String::with_capacity(lines.iter().map(|line| line.len() + 1).sum());
    for line in lines {
        data.push_str(line);
        data.push('\n');
    }
    atomic_write(path, data.as_bytes())?;
    Ok(json::hex(&Sha256::digest(data.as_bytes())))
}

/// Writes `data` to `path` through a temporary file in the same directory and a rename.
pub fn atomic_write(path: &Path, data: &[u8]) -> PackResult<()> {
    let staged = stage(path, data)?;
    publish(&staged, path)
}

/// Writes `data` beside `path` and returns where, without touching `path`: what a build prepares before it publishes.
pub fn stage(path: &Path, data: &[u8]) -> PackResult<PathBuf> {
    use std::io::Write as _;
    let parent = path.parent().filter(|parent| !parent.as_os_str().is_empty()).unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent)
        .map_err(|error| PackError::new(PackErrorKind::Missing, format!("{}: {error}", parent.display())))?;
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or("pack");
    let unique = std::process::id();
    let mut attempt = 0u32;
    // **Reserved with `create_new`, never tested then created**: two builds in one process can both find a name free,
    // and one would then truncate the other's temporary.
    let (temp, mut handle) = loop {
        let candidate = parent.join(format!(".{name}.{unique}.{attempt}"));
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&candidate) {
            Ok(handle) => break (candidate, handle),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                attempt += 1;
                if attempt > 1_000 {
                    return Err(PackError::new(
                        PackErrorKind::Missing,
                        format!("no free temporary name beside {}", path.display()),
                    ));
                }
            }
            Err(error) => {
                return Err(PackError::new(PackErrorKind::Missing, format!("{}: {error}", candidate.display())));
            }
        }
    };
    let result = (|| -> std::io::Result<()> {
        handle.write_all(data)?;
        handle.sync_all()?;
        drop(handle);
        Ok(())
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_file(&temp);
        return Err(PackError::new(PackErrorKind::Missing, format!("{}: {error}", temp.display())));
    }
    Ok(temp)
}

/// Moves a staged file onto `path`, which is the moment anything replaces a file already there.
pub fn publish(staged: &Path, path: &Path) -> PackResult<()> {
    std::fs::rename(staged, path).map_err(|error| {
        let _ = std::fs::remove_file(staged);
        PackError::new(PackErrorKind::Missing, format!("{}: {error}", path.display()))
    })
}

/// A path made absolute, resolving through the nearest ancestor that exists: an output not written yet still compares
/// against the checkout, where `canonicalize` alone leaves a relative path that matches nothing.
fn absolute(path: &Path) -> PathBuf {
    if let Ok(settled) = std::fs::canonicalize(path) {
        return settled;
    }
    let mut rest: Vec<std::ffi::OsString> = Vec::new();
    let mut at = path.to_path_buf();
    loop {
        let Some(name) = at.file_name().map(|name| name.to_os_string()) else { return path.to_path_buf() };
        rest.push(name);
        // A bare name has an empty parent: the working directory is where it would be written.
        let parent = at.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."));
        at = if parent.as_os_str().is_empty() { PathBuf::from(".") } else { parent };
        if let Ok(settled) = std::fs::canonicalize(&at) {
            return rest.iter().rev().fold(settled, |base, name| base.join(name));
        }
    }
}

/// Refuses an output path inside the Git checkout that holds `start`, so packs stay outside Git.
pub fn refuse_inside_repository(output: &Path, start: &Path) -> PackResult<()> {
    let start = absolute(start);
    let mut directory: Option<&Path> = Some(start.as_path());
    while let Some(current) = directory {
        if current.join(".git").exists() {
            let root = absolute(current);
            if absolute(output).starts_with(&root) {
                return Err(PackError::new(
                    PackErrorKind::Malformed,
                    format!(
                        "output {} is inside the repository {}; packs stay outside Git",
                        output.display(),
                        root.display()
                    ),
                ));
            }
            return Ok(());
        }
        directory = current.parent();
    }
    Ok(())
}
