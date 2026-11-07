//! The core, and what the service keeps beside it: the app's observations, which files each open dictionary is made
//! of, and the imports that can be cancelled. Every operation is the core's, with the wire's envelope around it.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use xdict_core::{
    ByteSource, Config, Core, CoreError, Location, MAX_SYNC_BYTES, Missing, Opened, Package,
    Progress, Resource, TextView, View,
};

use crate::failure::Failure;
use crate::handles::{HandleSource, Ledger, admit};
use crate::wire::{
    Answer, BASE_URL, BODY_MAX, BuildWordPackBody, CONTRACT, CloseBody, CollocatesBody,
    DefinitionHashBody, DictBody, EntryBody, EntryGlossBody, EntryTextBody, EraseBody,
    ExamplesBody, ExploreBody, FileRef, GradeBody, ImportBody, JoinLineageBody, LedgerHistoryBody,
    LedgerRecordBody, LedgerRemovalBody, LineageOfBody, LinkBody, LookupBody, OpenBody,
    PackageSpec, PhrasesBody, QueueBody, ReanchorBody, Request, ResolveBody, ResourceBody,
    SetWordPackBody, SplitLineageBody, StudyNoteAtBody, StudyNoteBody, SuggestBody, SummaryBody,
    SyncBody, TextViewBody, UndoBody,
};

/// Slow work tells the app how far it is; the app's answer can stop it.
pub trait Events: Send + Sync {
    fn progress(&self, id: u64, done: u64, total: u64);
}

/// An import's cancel state: the app's flag, and whether the import has passed the point where a cancel can stop it.
pub struct CancelState {
    flag: AtomicBool,
    /// Set once the core has reported its last byte; the registry follows, and a cancel after that would be a lie.
    committed: AtomicBool,
}

impl CancelState {
    fn new() -> Self {
        Self {
            flag: AtomicBool::new(false),
            committed: AtomicBool::new(false),
        }
    }
}

/// An import's progress: the core's counts to the app, and the app's cancel back.
struct ServiceProgress<'a> {
    id: u64,
    report: bool,
    cancel: Arc<CancelState>,
    events: &'a dyn Events,
}

impl Progress for ServiceProgress<'_> {
    fn progress(&self, done: u64, total: u64) -> bool {
        if self.report {
            self.events.progress(self.id, done, total);
        }
        if total > 0 && done >= total {
            self.cancel.committed.store(true, Ordering::Relaxed);
        }
        !self.cancel.flag.load(Ordering::Relaxed)
    }
}

/// The dictionaries a request names, decoded through the same body types its operation uses. A renamed field fails
/// here as it would in the operation, instead of silently skipping the observation check.
fn named_dicts(operation: &str, body: &Value) -> Result<Vec<String>, Failure> {
    fn one<T: DeserializeOwned>(body: &Value) -> Result<T, Failure> {
        serde_json::from_value(body.clone()).map_err(|error| {
            Failure::Core(CoreError::Malformed {
                detail: error.to_string(),
            })
        })
    }
    Ok(match operation {
        "lookup" => one::<LookupBody>(body)?.dicts,
        "suggest" => one::<SuggestBody>(body)?.dicts,
        "entry" => vec![one::<EntryBody>(body)?.dict],
        "entryText" => vec![one::<EntryTextBody>(body)?.dict],
        "resource" => vec![one::<ResourceBody>(body)?.dict],
        "link" => vec![one::<LinkBody>(body)?.dict],
        // Contract 5's dictionary-named reads: each names handles, so each requires its dictionaries' observations.
        "explore" => one::<ExploreBody>(body)?.dicts,
        "collocates" => one::<CollocatesBody>(body)?.dicts,
        "examples" => one::<ExamplesBody>(body)?.dicts,
        "phrases" => one::<PhrasesBody>(body)?.dicts,
        "examplesBuild" | "phrasesBuild" => vec![one::<DictBody>(body)?.dict],
        // Contract 2's handle-named reads: a note's definition and its hash both read the entry, so the dictionary's
        // observations are required exactly as they are for an entry read.
        "studyNote" => vec![one::<StudyNoteBody>(body)?.dict],
        "definitionHash" => vec![one::<DefinitionHashBody>(body)?.dict],
        "close" | "health" | "readingStyle" | "displayOptions" => vec![one::<DictBody>(body)?.dict],
        _ => Vec::new(),
    })
}

/// The editions an operation names instead of a handle. Admission resolves each through the service's edition→open
/// map, so the operation's files are checked even though the app sent no dictionary handle (`CONTRACT.md` §3).
fn named_editions(operation: &str, body: &Value) -> Result<Vec<String>, Failure> {
    fn one<T: DeserializeOwned>(body: &Value) -> Result<T, Failure> {
        serde_json::from_value(body.clone()).map_err(|error| {
            Failure::Core(CoreError::Malformed {
                detail: error.to_string(),
            })
        })
    }
    Ok(match operation {
        "entryGloss" => vec![one::<EntryGlossBody>(body)?.entry.edition],
        "studyNoteAt" => vec![one::<StudyNoteAtBody>(body)?.entry.edition],
        "studyReanchor" => vec![one::<ReanchorBody>(body)?.new_edition],
        _ => Vec::new(),
    })
}

pub struct Service {
    core: Core,
    ledger: Arc<Ledger>,
    files_of: Mutex<HashMap<String, Vec<String>>>,
    /// Which open dictionary a contract-2 operation names by edition. A fresh service has no entry, which is what
    /// makes `notFound(.edition)` a real answer the client reopens from.
    editions: Mutex<HashMap<String, String>>,
    edition_of: Mutex<HashMap<String, String>>,
    cancels: Mutex<HashMap<u64, Arc<CancelState>>>,
    /// The service-owned folders a sync's input and output meet in; the reader's folder never has a path here.
    staging: PathBuf,
    sync_serial: AtomicU64,
    /// Serialises the first exploration's load of the persisted pack, so two calls do not parse 183 MB twice.
    pack_lock: Mutex<()>,
}

impl Service {
    pub fn new(core: Core, staging: PathBuf) -> Self {
        // A killed sync or pack operation leaves its own folder; the next service start sweeps them all before any
        // work runs. The persisted pack is not staging and is never swept.
        let _ = std::fs::remove_dir_all(staging.join("ledger-sync"));
        let _ = std::fs::remove_dir_all(staging.join("word-pack-staging"));
        let _ = std::fs::remove_dir_all(staging.join("word-pack-build"));
        Self {
            core,
            ledger: Arc::new(Ledger::default()),
            files_of: Mutex::new(HashMap::new()),
            editions: Mutex::new(HashMap::new()),
            edition_of: Mutex::new(HashMap::new()),
            cancels: Mutex::new(HashMap::new()),
            staging,
            sync_serial: AtomicU64::new(0),
            pack_lock: Mutex::new(()),
        }
    }

    /// `cancel` is answered at once, before any gate; every other operation runs here.
    pub fn cancel_request(&self, id: u64) -> bool {
        self.cancels
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&id)
            .is_some_and(|state| {
                // Past the core's last check the import will register and answer Imported: saying "cancelled"
                // then would contradict the reply the reader is about to receive.
                if state.committed.load(Ordering::Relaxed) {
                    return false;
                }
                state.flag.store(true, Ordering::Relaxed);
                true
            })
    }

    pub fn run(&self, request: &Request, events: &dyn Events) -> Result<Answer, Failure> {
        let sources = self.admit_request(request)?;
        self.dispatch(request, events, sources)
    }

    /// Admits every file the request names and checks each named dictionary's observations, before any operation
    /// decodes: a temporary duplicate is owned and closed even when the operation is refused.
    fn admit_request(&self, request: &Request) -> Result<HashMap<String, HandleSource>, Failure> {
        let sync = request.op == "ledgerSync";
        let sources = admit(&request.files, &self.ledger, sync)?;
        if sync {
            let outputs = request.files.iter().filter(|spec| spec.write).count();
            if outputs != 1 {
                return Err(Failure::admission(
                    "ledgerSync needs exactly one writable destination",
                ));
            }
            let inputs: Vec<&crate::wire::FileSpec> =
                request.files.iter().filter(|spec| !spec.write).collect();
            if inputs.len() > 64 {
                return Err(Failure::admission(format!(
                    "ledgerSync names {} peers; the bound is 64",
                    inputs.len()
                )));
            }
            let mut aggregate = 0u64;
            for spec in inputs {
                let Some(source) = sources.get(&spec.id) else {
                    return Err(Failure::admission(format!(
                        "{}: the peer was not admitted",
                        spec.id
                    )));
                };
                let size = source.size();
                if size > MAX_SYNC_BYTES {
                    return Err(Failure::admission(format!(
                        "{}: the peer is {size} bytes; the bound is {MAX_SYNC_BYTES}",
                        spec.id
                    )));
                }
                aggregate = aggregate
                    .checked_add(size)
                    .ok_or_else(|| Failure::admission("the peers' aggregate size overflows"))?;
                if aggregate > MAX_SYNC_BYTES {
                    return Err(Failure::admission(format!(
                        "the peers' aggregate is over {MAX_SYNC_BYTES} bytes"
                    )));
                }
            }
        }
        let mut dicts = named_dicts(&request.op, &request.operation)?;
        // An edition-named operation reads the dictionary open under that edition; the app never names its handle,
        // so admission resolves it here and then checks that dictionary's files like any other.
        for edition in named_editions(&request.op, &request.operation)? {
            let editions = self
                .editions
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let Some(dict) = editions.get(&edition).cloned() else {
                return Err(Failure::Core(CoreError::NotFound {
                    what: Missing::Edition,
                    detail: format!("{edition} is not open"),
                }));
            };
            dicts.push(dict);
        }
        if request.op != "close" {
            let packages = self.files_of.lock().unwrap_or_else(|p| p.into_inner());
            for dict in dicts {
                if let Some(ids) = packages.get(&dict)
                    && ids.iter().any(|id| !sources.contains_key(id))
                {
                    return Err(Failure::admission(
                        "missing observation for a dictionary file",
                    ));
                }
            }
        }
        Ok(sources)
    }

    fn dispatch(
        &self,
        request: &Request,
        events: &dyn Events,
        sources: HashMap<String, HandleSource>,
    ) -> Result<Answer, Failure> {
        match request.op.as_str() {
            #[cfg(feature = "acceptance-probes")]
            "acceptanceProbe" => {
                let path = request
                    .operation
                    .get("path")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let address = request
                    .operation
                    .get("address")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let path_error = std::fs::File::open(path)
                    .err()
                    .and_then(|error| error.raw_os_error());
                let address: std::net::SocketAddr = address
                    .parse()
                    .map_err(|_| Failure::admission("probe address"))?;
                let network = std::net::TcpStream::connect_timeout(
                    &address,
                    std::time::Duration::from_secs(2),
                );
                record(
                    json!({"pathError": path_error, "networkConnected": network.is_ok(),
                    "networkError": network.as_ref().err().and_then(|error| error.raw_os_error()),
                    "networkKind": network.as_ref().err().map(|error| format!("{:?}", error.kind()))}),
                )
            }
            "versions" => record(Core::versions()),
            "import" => self.import(request, events, sources),
            "open" => self.open(request, sources),
            "close" => self.close(request),
            "lookup" => {
                let body: LookupBody = decode(&request.operation)?;
                record(self.core.lookup(body.query, body.dicts, body.options)?)
            }
            "suggest" => {
                let body: SuggestBody = decode(&request.operation)?;
                record(self.core.suggest(body.prefix, body.dicts, body.limit)?)
            }
            "entry" => self.entry(request),
            "entryText" => {
                let body: EntryTextBody = decode(&request.operation)?;
                record(
                    self.core
                        .entry_text(body.dict, body.entry, text_view(body.view)?)?,
                )
            }
            "link" => {
                let body: LinkBody = decode(&request.operation)?;
                let view = view(body.view)?;
                record(self.core.link(body.dict, body.url, body.origin, view)?)
            }
            "resource" => self.resource(request),
            "health" => {
                let body: DictBody = decode(&request.operation)?;
                record(self.core.health(body.dict, &xdict_core::NoProgress)?)
            }
            "displayOptions" => {
                let body: DictBody = decode(&request.operation)?;
                record(self.core.display_options(body.dict)?)
            }
            "readingStyle" => {
                let body: DictBody = decode(&request.operation)?;
                record(self.core.reading_style(body.dict)?)
            }
            "joinLineage" => {
                let body: JoinLineageBody = decode(&request.operation)?;
                record(self.core.join_lineage(body.edition, body.lineage)?)
            }
            "splitLineage" => {
                let body: SplitLineageBody = decode(&request.operation)?;
                record(self.core.split_lineage(body.edition, body.new_lineage)?)
            }
            "lineageOf" => {
                let body: LineageOfBody = decode(&request.operation)?;
                record(self.core.lineage_of(body.edition)?)
            }
            // MARK: contract 2 — the learning set
            "entryGloss" => {
                let body: EntryGlossBody = decode(&request.operation)?;
                record(self.core.entry_gloss(body.entry)?)
            }
            "ledgerRecord" => {
                let body: LedgerRecordBody = decode(&request.operation)?;
                record(self.core.ledger_record(
                    body.reading,
                    body.operation,
                    body.target_languages,
                )?)
            }
            "ledgerHistory" => {
                let body: LedgerHistoryBody = decode(&request.operation)?;
                record(
                    self.core
                        .ledger_history(body.now, body.utc_offset_seconds)?,
                )
            }
            "ledgerRemove" => {
                let body: LedgerRemovalBody = decode(&request.operation)?;
                record(self.core.ledger_remove(body.removal, body.operation)?)
            }
            "ledgerRestore" => {
                let body: LedgerRemovalBody = decode(&request.operation)?;
                record(self.core.ledger_restore(body.removal, body.operation)?)
            }
            "exportData" => {
                let bytes = self.core.ledger_export_json()?.into_bytes();
                Ok(Answer {
                    record: json!({}),
                    payload: Some((bytes, "application/json".to_string())),
                })
            }
            "eraseData" => {
                let body: EraseBody = decode(&request.operation)?;
                record(
                    self.core
                        .ledger_erase(body.operation, body.stamp.at, body.stamp.device)?,
                )
            }
            "studyNote" => {
                let body: StudyNoteBody = decode(&request.operation)?;
                record(self.core.study_note(
                    body.dict,
                    body.entry,
                    body.text,
                    body.name,
                    body.stamp,
                    body.operation,
                )?)
            }
            "studyNoteAt" => {
                let body: StudyNoteAtBody = decode(&request.operation)?;
                record(self.core.study_note_at(
                    body.entry,
                    body.text,
                    body.name,
                    body.stamp,
                    body.operation,
                )?)
            }
            "studyNotes" => record(self.core.study_notes()?),
            "definitionHash" => {
                let body: DefinitionHashBody = decode(&request.operation)?;
                record(self.core.definition_hash_of(body.dict, body.entry)?)
            }
            "studyReanchor" => {
                let body: ReanchorBody = decode(&request.operation)?;
                record(self.core.study_reanchor(
                    body.old_edition,
                    body.new_edition,
                    body.stamp,
                    body.operation_prefix,
                )?)
            }
            "reviewQueue" => {
                let body: QueueBody = decode(&request.operation)?;
                record(self.core.review_queue(body.now, body.limit)?)
            }
            "reviewGrade" => {
                let body: GradeBody = decode(&request.operation)?;
                record(self.core.review_grade(
                    body.target,
                    body.revision,
                    body.grade.number(),
                    body.policy,
                    body.stamp,
                    body.operation,
                )?)
            }
            "reviewUndo" => {
                let body: UndoBody = decode(&request.operation)?;
                record(self.core.review_undo(
                    body.target,
                    body.grade_event,
                    body.stamp,
                    body.operation,
                )?)
            }
            "reviewSummary" => {
                let body: SummaryBody = decode(&request.operation)?;
                record(self.core.review_summary(body.now)?)
            }
            "studyConflicts" => record(self.core.review_conflicts()?),
            "reviewResolve" => {
                let body: ResolveBody = decode(&request.operation)?;
                record(self.core.review_resolve(
                    body.target,
                    body.keep,
                    body.stamp,
                    body.operation,
                )?)
            }
            "ledgerSync" => {
                let body: SyncBody = decode(&request.operation)?;
                self.ledger_sync(body, sources)
            }
            // MARK: contract 5 — Explore and its stores
            "explore" => {
                self.ensure_pack_loaded();
                let body: ExploreBody = decode(&request.operation)?;
                record(self.core.explore(
                    body.dicts,
                    body.mode,
                    body.text,
                    body.offset,
                    body.limit,
                )?)
            }
            "collocates" => {
                let body: CollocatesBody = decode(&request.operation)?;
                let rows = self.core.collocates(body.query, body.dicts, body.limit)?;
                record(rows.iter().map(collocation_json).collect::<Vec<_>>())
            }
            "wordPack" => {
                self.ensure_pack_loaded();
                record(json!({ "pack": self.core.word_pack() }))
            }
            "setWordPack" => self.set_word_pack(request, sources),
            "clearWordPack" => {
                // The same lock as loading, installing and building: the four transitions are one state machine.
                let _pack = self
                    .pack_lock
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                self.core.detach_word_pack();
                let installed = self.installed_pack();
                if let Err(error) = std::fs::remove_file(&installed)
                    && error.kind() != std::io::ErrorKind::NotFound
                {
                    // Reporting success would leave the pack on disk for the next lazy load to install again.
                    return Err(Failure::Core(CoreError::Io {
                        kind: xdict_core::IoKind::Other,
                        detail: format!(
                            "the installed word pack {} could not be removed: {error}",
                            installed.display()
                        ),
                    }));
                }
                record(json!({ "pack": null }))
            }
            "buildWordPack" => self.build_word_pack(request, events, sources),
            "examples" => {
                let body: ExamplesBody = decode(&request.operation)?;
                record(self.core.examples(body.query, body.dicts, body.limit)?)
            }
            "examplesBuild" => {
                let body: DictBody = decode(&request.operation)?;
                let progress = self.build_progress(request.id, events);
                record(self.core.examples_build(body.dict, &progress)?)
            }
            "phrases" => {
                let body: PhrasesBody = decode(&request.operation)?;
                record(self.core.phrases(
                    body.sentence,
                    body.term.location,
                    body.term.length,
                    body.dicts,
                )?)
            }
            "phrasesBuild" => {
                let body: DictBody = decode(&request.operation)?;
                let progress = self.build_progress(request.id, events);
                record(self.core.phrases_build(body.dict, &progress)?)
            }
            other => Err(Failure::Core(CoreError::Malformed {
                detail: format!("the operation {other} is not in contract {CONTRACT}"),
            })),
        }
    }

    /// Contract 3's one pass: copy the admitted peer handles into the service's staging inbox, let the core merge them
    /// and write this device's log, then copy that log through the app's one writable handle. No reader path is read.
    fn ledger_sync(
        &self,
        body: SyncBody,
        sources: HashMap<String, HandleSource>,
    ) -> Result<Answer, Failure> {
        let mut output = None;
        let mut inputs = Vec::new();
        for source in sources.into_values() {
            if source.is_write() {
                output = Some(source);
            } else {
                inputs.push(source);
            }
        }
        let mut output =
            output.ok_or_else(|| Failure::admission("ledgerSync has no writable destination"))?;
        let serial = self.sync_serial.fetch_add(1, Ordering::Relaxed);
        let root = self
            .staging
            .join("ledger-sync")
            .join(format!("{}-{serial}", std::process::id()));
        let inbox = root.join("in");
        let outbox = root.join("out");
        let device = body.device;
        let result = (|| -> Result<Answer, Failure> {
            std::fs::create_dir_all(&inbox)
                .map_err(CoreError::from)
                .map_err(Failure::Core)?;
            std::fs::create_dir_all(&outbox)
                .map_err(CoreError::from)
                .map_err(Failure::Core)?;
            for (index, source) in inputs.iter().enumerate() {
                let path = inbox.join(sync_name(source.name(), index));
                source.copy_to(&path)?;
            }
            let report = self.core.ledger_sync(
                inbox.to_string_lossy().into_owned(),
                outbox.to_string_lossy().into_owned(),
                device.clone(),
            )?;
            let ours = outbox.join(format!("xdict-{device}.xdlog"));
            output.write_from(&ours)?;
            record(report)
        })();
        if let Err(error) = std::fs::remove_dir_all(&root) {
            eprintln!(
                "the sync staging {} could not be removed: {error}",
                root.display()
            );
        }
        result
    }

    /// A long store build's progress: the core's counts to the app, and the app's cancel back. The server loop
    /// registered this request's flag before the thread ran, as it does for an import.
    fn build_progress<'a>(&self, id: u64, events: &'a dyn Events) -> ServiceProgress<'a> {
        ServiceProgress {
            id,
            report: true,
            cancel: self.cancel_state(id),
            events,
        }
    }

    /// Contract 5's pack install: copy the admitted handle into the service's staging profile, let the core validate
    /// it there, and keep the pack the core loaded. No path the app chose is ever read, and a refusal leaves the pack
    /// already held in place (the core's own rule).
    fn set_word_pack(
        &self,
        request: &Request,
        mut sources: HashMap<String, HandleSource>,
    ) -> Result<Answer, Failure> {
        let _pack = self
            .pack_lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let body: SetWordPackBody = decode(&request.operation)?;
        let source = sources.remove(&body.file.file).ok_or_else(|| {
            Failure::admission(format!(
                "the word pack names {}, which the request did not send",
                body.file.file
            ))
        })?;
        let serial = self.sync_serial.fetch_add(1, Ordering::Relaxed);
        let root = self
            .staging
            .join("word-pack-staging")
            .join(format!("{}-{serial}", std::process::id()));
        let result = (|| -> Result<Answer, Failure> {
            std::fs::create_dir_all(&root)
                .map_err(CoreError::from)
                .map_err(Failure::Core)?;
            let path = root.join("pack.jsonl");
            source.copy_to(&path)?;
            let info = self
                .core
                .attach_word_pack(path.to_string_lossy().into_owned())?;
            if let Err(error) = self.persist_pack(&path) {
                eprintln!(
                    "the installed word pack could not be persisted: {}",
                    error.to_value()
                );
            }
            record(json!({ "pack": info }))
        })();
        if let Err(error) = std::fs::remove_dir_all(&root) {
            eprintln!(
                "the word-pack staging {} could not be removed: {error}",
                root.display()
            );
        }
        result
    }

    /// Contract 5's pack build: the app downloaded the pinned sources and their manifest; the service copies every
    /// handle into its own staging folder under the names the manifest pins, builds and installs the pack there, and
    /// removes the folder. The app never supplies a path the service reads.
    fn build_word_pack(
        &self,
        request: &Request,
        events: &dyn Events,
        mut sources: HashMap<String, HandleSource>,
    ) -> Result<Answer, Failure> {
        let _pack = self
            .pack_lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let body: BuildWordPackBody = decode(&request.operation)?;
        if body.sources.len() > 64 {
            return Err(Failure::admission(format!(
                "buildWordPack names {} sources; the bound is 64",
                body.sources.len()
            )));
        }
        let serial = self.sync_serial.fetch_add(1, Ordering::Relaxed);
        let root = self
            .staging
            .join("word-pack-build")
            .join(format!("{}-{serial}", std::process::id()));
        let result = (|| -> Result<Answer, Failure> {
            let raw = root.join("sources");
            let out = root.join("out");
            std::fs::create_dir_all(&raw)
                .map_err(CoreError::from)
                .map_err(Failure::Core)?;
            std::fs::create_dir_all(&out)
                .map_err(CoreError::from)
                .map_err(Failure::Core)?;
            let mut staged = std::collections::HashSet::new();
            for file in &body.sources {
                let source = sources.remove(&file.file).ok_or_else(|| {
                    Failure::admission(format!(
                        "buildWordPack names {}, which the request did not send",
                        file.file
                    ))
                })?;
                // The manifest pins a plain file name and the core joins it under the raw folder; a source renamed
                // here would make every pinned SHA-256 fail, so the name is kept exactly or the build is refused.
                let name = source.name();
                if !plain_source_name(name) || !staged.insert(name.to_string()) {
                    return Err(Failure::admission(format!(
                        "{}: the source name {name:?} cannot be staged for its manifest",
                        file.file
                    )));
                }
                source.copy_to(&raw.join(name))?;
            }
            let manifest = sources.remove(&body.manifest.file).ok_or_else(|| {
                Failure::admission(format!(
                    "the manifest names {}, which the request did not send",
                    body.manifest.file
                ))
            })?;
            let manifest_path = root.join("manifest.json");
            manifest.copy_to(&manifest_path)?;
            let output = out.join("xdict-word-pack.jsonl");
            let progress = self.build_progress(request.id, events);
            let info = self.core.build_word_pack(
                raw.to_string_lossy().into_owned(),
                manifest_path.to_string_lossy().into_owned(),
                output.to_string_lossy().into_owned(),
                &progress,
            )?;
            if let Err(error) = self.persist_pack(&output) {
                eprintln!(
                    "the built word pack could not be persisted: {}",
                    error.to_value()
                );
            }
            record(json!({ "pack": info }))
        })();
        if let Err(error) = std::fs::remove_dir_all(&root) {
            eprintln!(
                "the word-pack build staging {} could not be removed: {error}",
                root.display()
            );
        }
        result
    }

    fn import(
        &self,
        request: &Request,
        events: &dyn Events,
        mut sources: HashMap<String, HandleSource>,
    ) -> Result<Answer, Failure> {
        let body: ImportBody = decode(&request.operation)?;
        // Import must not register bytes the app did not observe. A path replaced under a held handle is refused
        // here, where the handle's identity and the request's observation are both in hand; lookup keeps its
        // SourceChanged answer instead (handles.rs admission admits the old object on purpose).
        for file in &request.files {
            let Some(source) = sources.get(&file.id) else {
                continue;
            };
            let changed = matches!(
                (source.held_identity(), file.identity),
                (Ok(held), Some(observed)) if held != observed
            );
            if changed {
                return Err(Failure::Core(CoreError::SourceChanged {
                    detail: format!("{}: the file changed as it was imported", file.id),
                }));
            }
        }
        let package = self.package(&body.package, &mut sources)?;
        // The server registers the flag before this runs; this is only a fallback for a direct caller.
        let cancel = self.cancel_state(request.id);
        let progress = ServiceProgress {
            id: request.id,
            report: body.progress,
            cancel,
            events,
        };
        // Removal belongs to the server loop that registered it; a direct caller keeps no map entry to leak.
        let imported = self.core.import(package, &progress);
        let imported = imported?;
        record(imported)
    }

    fn open(
        &self,
        request: &Request,
        mut sources: HashMap<String, HandleSource>,
    ) -> Result<Answer, Failure> {
        let body: OpenBody = decode(&request.operation)?;
        let package = self.package(&body.package, &mut sources)?;
        let ids = package_ids(&body.package);
        let opened = self.core.open(package)?;
        if let Opened::Ready { dict, edition, .. } = &opened {
            self.files_of
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .insert(dict.clone(), ids);
            self.editions
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .insert(edition.clone(), dict.clone());
            self.edition_of
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .insert(dict.clone(), edition.clone());
        }
        record(opened)
    }

    fn close(&self, request: &Request) -> Result<Answer, Failure> {
        let body: CloseBody = decode(&request.operation)?;
        self.core.close(body.dict.clone())?;
        self.files_of
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&body.dict);
        if let Some(edition) = self
            .edition_of
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&body.dict)
        {
            let mut editions = self
                .editions
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if editions.get(&edition) == Some(&body.dict) {
                editions.remove(&edition);
            }
        }
        Ok(Answer {
            record: json!("closed"),
            payload: None,
        })
    }

    fn entry(&self, request: &Request) -> Result<Answer, Failure> {
        let body: EntryBody = decode(&request.operation)?;
        let view = view(body.view)?;
        let entry = self.core.entry(body.dict, body.entry, view)?;
        let payload = entry.html.into_bytes();
        Ok(Answer {
            record: json!({"entry": entry.entry, "csp": entry.csp, "lossyBytes": entry.lossy_bytes}),
            payload: Some((payload, "text/html".to_string())),
        })
    }

    fn resource(&self, request: &Request) -> Result<Answer, Failure> {
        let body: ResourceBody = decode(&request.operation)?;
        let view = view(body.view)?;
        match self.core.resource(body.dict, body.path, view)? {
            Resource::Found { path, mime, bytes } => {
                let announced = mime.clone();
                Ok(Answer {
                    record: json!({"type": "found", "path": path, "mime": announced}),
                    payload: Some((bytes, mime)),
                })
            }
            Resource::Missing { path } => Ok(Answer {
                record: json!({"type": "missing", "path": path}),
                payload: None,
            }),
        }
    }

    fn package(
        &self,
        spec: &PackageSpec,
        sources: &mut HashMap<String, HandleSource>,
    ) -> Result<Package, Failure> {
        let mut take = |file: &FileRef| -> Result<Location, Failure> {
            let source = sources.remove(&file.file).ok_or_else(|| {
                Failure::admission(format!(
                    "the package names {}, which the request did not send",
                    file.file
                ))
            })?;
            let name = source.name().to_string();
            Ok(Location::Source {
                name,
                source: Arc::new(source),
            })
        };
        let mdx = take(&spec.mdx)?;
        let mut mdd = Vec::with_capacity(spec.mdd.len());
        for file in &spec.mdd {
            mdd.push(take(file)?);
        }
        let mut sidecars = Vec::with_capacity(spec.sidecars.len());
        for file in &spec.sidecars {
            sidecars.push(take(file)?);
        }
        Ok(Package { mdx, mdd, sidecars })
    }

    /// The first word-pack question on a restarted service loads the persisted pack: the service was idle, not
    /// gone, and a missing pack would otherwise turn every pack mode into "not installed". A corrupt file is
    /// removed after one refusal.
    fn ensure_pack_loaded(&self) {
        if self.core.word_pack().is_some() {
            return;
        }
        let installed = self.installed_pack();
        if !installed.is_file() {
            return;
        }
        let _guard = self
            .pack_lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if self.core.word_pack().is_some() {
            return;
        }
        if let Err(error) = self
            .core
            .attach_word_pack(installed.to_string_lossy().into_owned())
        {
            eprintln!(
                "the installed word pack {} could not be loaded: {error:?}",
                installed.display()
            );
            let _ = std::fs::remove_file(&installed);
        }
    }

    /// The pack the service keeps across restarts: app data, never the reader's file and never a staging folder.
    fn installed_pack(&self) -> PathBuf {
        self.staging.join("word-pack").join("installed.jsonl")
    }

    /// Copies a pack the core has just loaded into the persistent file, replacing the previous one only after the
    /// copy is whole. A failure leaves the pack held in memory and is logged; the operation itself has succeeded.
    fn persist_pack(&self, from: &Path) -> Result<(), Failure> {
        let directory = self.staging.join("word-pack");
        std::fs::create_dir_all(&directory)
            .map_err(CoreError::from)
            .map_err(Failure::Core)?;
        let target = directory.join("installed.jsonl");
        // A temporary of its own per call: two installations must not truncate each other's copy.
        let temp = directory.join(format!(
            "installed.{}-{}.jsonl.tmp",
            std::process::id(),
            self.sync_serial.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::copy(from, &temp)
            .map_err(CoreError::from)
            .map_err(Failure::Core)?;
        // Rename replaces atomically; deleting the old pack first turned a crash between the two into data loss.
        std::fs::rename(&temp, &target)
            .map_err(CoreError::from)
            .map_err(Failure::Core)
    }

    /// The flag for this id when one was registered before the import started; otherwise a fresh, unregistered one.
    fn cancel_state(&self, id: u64) -> Arc<CancelState> {
        self.cancels
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&id)
            .cloned()
            .unwrap_or_else(|| Arc::new(CancelState::new()))
    }

    /// The flag the reader registered for this id, or a new one: a cancel that arrived before the import started
    /// must still reach the import.
    pub fn register_cancel(&self, id: u64) -> Arc<CancelState> {
        let mut cancels = self
            .cancels
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(existing) = cancels.get(&id) {
            return existing.clone();
        }
        let state = Arc::new(CancelState::new());
        cancels.insert(id, state.clone());
        state
    }

    pub fn finish_cancel(&self, id: u64) {
        self.cancels
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&id);
    }
}

/// Whether an operation is bulk-class: two at a time. The contract-2 learning operations read a body or the whole log,
/// so they hold a bulk credit like an entry or a resource (`CONTRACT.md` §5).
pub fn is_bulk(op: &str) -> bool {
    matches!(
        op,
        "entry"
            | "resource"
            | "entryText"
            | "entryGloss"
            | "exportData"
            | "studyNote"
            | "studyNoteAt"
            | "definitionHash"
            | "studyReanchor"
    )
}

/// One collocation as the wire carries it: the core's frame vocabulary under the contract's camelCase names. The core
/// type does not implement serde (it belongs to the entry crate), so this is the one mapping.
fn collocation_json(row: &xdict_core::collocations::Collocation) -> Value {
    json!({
        "lemma": row.lemma,
        "frame": frame_name(row.frame),
        "partner": row.partner,
        "dict": row.dict,
        "entry": row.entry,
    })
}

fn frame_name(frame: xdict_core::collocations::Frame) -> &'static str {
    use xdict_core::collocations::Frame;
    match frame {
        Frame::Adjective => "adjective",
        Frame::Adverb => "adverb",
        Frame::Noun => "noun",
        Frame::Verb => "verb",
        Frame::Verbs => "verbs",
        Frame::Preposition => "preposition",
        Frame::Phrases => "phrases",
        Frame::AdjectivePlusHeadword => "adjectivePlusHeadword",
        Frame::VerbPlusHeadword => "verbPlusHeadword",
        Frame::HeadwordPlusVerb => "headwordPlusVerb",
        Frame::HeadwordPlusNoun => "headwordPlusNoun",
        Frame::NounPlusHeadword => "nounPlusHeadword",
        Frame::PhraseOfHeadword => "phraseOfHeadword",
    }
}

/// Whether a pack source's name is one the manifest can pin: a plain file name (`manifest.rs`'s own rule), never a
/// path or a name with a separator. The manifest joins it under the staging folder, so anything else is a refusal.
fn plain_source_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    first.is_ascii_alphanumeric()
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

/// The staging name a peer log is copied under: its own file name when it is safe, one `.xdlog` suffix, and an
/// index so two peers with the same name cannot shadow each other. The reader's path never becomes this name.
fn sync_name(name: &str, index: usize) -> String {
    let base = Path::new(name)
        .file_name()
        .and_then(|part| part.to_str())
        .unwrap_or("peer.xdlog");
    let named = if base.ends_with(".xdlog") {
        base.to_string()
    } else {
        format!("{base}.xdlog")
    };
    format!("{index:02}-{named}")
}

fn package_ids(spec: &PackageSpec) -> Vec<String> {
    let mut ids = vec![spec.mdx.file.clone()];
    ids.extend(spec.mdd.iter().map(|file| file.file.clone()));
    ids.extend(spec.sidecars.iter().map(|file| file.file.clone()));
    ids
}

/// The render context, with the service's base: no request can move it.
/// The contract's text budget: the macOS `Limits.maxTextBytes`.
const TEXT_MAX: u64 = 1 << 20;

/// The entry-text view: the service's base, the body ceiling and the text budget both bounded, never the request's.
fn text_view(requested: TextViewBody) -> Result<TextView, Failure> {
    let _ = requested.base_url;
    if requested.max_body_bytes == 0 || requested.max_body_bytes > BODY_MAX {
        return Err(Failure::admission(format!(
            "the view's body ceiling {} is outside 1..={BODY_MAX}",
            requested.max_body_bytes
        )));
    }
    if requested.max_text_bytes == 0 || requested.max_text_bytes > TEXT_MAX {
        return Err(Failure::admission(format!(
            "the text budget {} is outside 1..={TEXT_MAX}",
            requested.max_text_bytes
        )));
    }
    Ok(TextView {
        base_url: BASE_URL.to_string(),
        max_body_bytes: requested.max_body_bytes,
        max_text_bytes: requested.max_text_bytes,
        original_style: requested.original_style,
    })
}

fn view(requested: View) -> Result<View, Failure> {
    if requested.max_body_bytes == 0 || requested.max_body_bytes > BODY_MAX {
        return Err(Failure::admission(format!(
            "the view's body ceiling {} is outside 1..={BODY_MAX}",
            requested.max_body_bytes
        )));
    }
    Ok(View {
        base_url: BASE_URL.to_string(),
        max_body_bytes: requested.max_body_bytes,
        original_style: requested.original_style,
    })
}

fn decode<T: DeserializeOwned>(body: &Value) -> Result<T, Failure> {
    serde_json::from_value(body.clone()).map_err(|error| {
        Failure::Core(CoreError::Malformed {
            detail: format!("the operation's body did not decode: {error}"),
        })
    })
}

fn record<T: serde::Serialize>(value: T) -> Result<Answer, Failure> {
    let record = serde_json::to_value(value).map_err(|error| {
        Failure::Core(CoreError::Internal {
            detail: format!("the answer did not encode: {error}"),
        })
    })?;
    Ok(Answer {
        record,
        payload: None,
    })
}

/// Builds the core with the storage the app named: the container's own folders.
pub fn core_from(data: Option<String>, cache: Option<String>) -> Result<Core, CoreError> {
    Core::new(Config {
        data_dir: data,
        cache_dir: cache,
        client_protocol: xdict_core::PROTOCOL,
        ..Config::default()
    })
}
