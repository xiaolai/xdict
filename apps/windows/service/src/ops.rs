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
    Progress, Resource, View,
};

use crate::failure::Failure;
use crate::handles::{HandleSource, Ledger, admit};
use crate::wire::{
    Answer, BASE_URL, BODY_MAX, CONTRACT, CloseBody, DefinitionHashBody, DictBody, EntryBody,
    EntryGlossBody, EraseBody, FileRef, GradeBody, ImportBody, JoinLineageBody, LedgerHistoryBody,
    LedgerRecordBody, LedgerRemovalBody, LineageOfBody, LinkBody, LookupBody, OpenBody,
    PackageSpec, QueueBody, ReanchorBody, Request, ResolveBody, ResourceBody, SplitLineageBody,
    StudyNoteAtBody, StudyNoteBody, SuggestBody, SummaryBody, SyncBody, UndoBody,
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
        "resource" => vec![one::<ResourceBody>(body)?.dict],
        "link" => vec![one::<LinkBody>(body)?.dict],
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
}

impl Service {
    pub fn new(core: Core, staging: PathBuf) -> Self {
        // A killed sync leaves its own folder; the next service start sweeps them all before any work runs.
        let _ = std::fs::remove_dir_all(staging.join("ledger-sync"));
        Self {
            core,
            ledger: Arc::new(Ledger::default()),
            files_of: Mutex::new(HashMap::new()),
            editions: Mutex::new(HashMap::new()),
            edition_of: Mutex::new(HashMap::new()),
            cancels: Mutex::new(HashMap::new()),
            staging,
            sync_serial: AtomicU64::new(0),
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
            | "entryGloss"
            | "exportData"
            | "studyNote"
            | "studyNoteAt"
            | "definitionHash"
            | "studyReanchor"
    )
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
