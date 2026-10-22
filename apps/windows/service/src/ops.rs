//! The core, and what the service keeps beside it: the app's observations, which files each open dictionary is made
//! of, and the imports that can be cancelled. Every operation is the core's, with the wire's envelope around it.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use xdict_core::{Config, Core, CoreError, Location, Opened, Package, Progress, Resource, View};

use crate::failure::Failure;
use crate::handles::{HandleSource, Ledger, admit};
use crate::wire::{
    Answer, BASE_URL, BODY_MAX, CONTRACT, CloseBody, DictBody, EntryBody, FileRef, ImportBody,
    JoinLineageBody, LineageOfBody, LinkBody, LookupBody, OpenBody, PackageSpec, Request,
    ResourceBody, SplitLineageBody, SuggestBody,
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

pub struct Service {
    core: Core,
    ledger: Arc<Ledger>,
    files_of: Mutex<HashMap<String, Vec<String>>>,
    cancels: Mutex<HashMap<u64, Arc<CancelState>>>,
}

impl Service {
    pub fn new(core: Core) -> Self {
        Self {
            core,
            ledger: Arc::new(Ledger::default()),
            files_of: Mutex::new(HashMap::new()),
            cancels: Mutex::new(HashMap::new()),
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
        // Every operation that may read updates path observations, including lookup/entry/resource on held sources.
        // Admit once here so temporary duplicates are owned and closed even when the operation is refused.
        let sources = admit(&request.files, &self.ledger)?;
        let mut dicts = Vec::new();
        if let Some(dict) = request.operation.get("dict").and_then(Value::as_str) {
            dicts.push(dict);
        }
        if let Some(named) = request.operation.get("dicts").and_then(Value::as_array) {
            dicts.extend(named.iter().filter_map(Value::as_str));
        }
        if request.op != "close" {
            let packages = self.files_of.lock().unwrap_or_else(|p| p.into_inner());
            for dict in dicts {
                if let Some(ids) = packages.get(dict)
                    && ids.iter().any(|id| !sources.contains_key(id))
                {
                    return Err(Failure::admission(
                        "missing observation for a dictionary file",
                    ));
                }
            }
        }
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
            other => Err(Failure::Core(CoreError::Malformed {
                detail: format!("the operation {other} is not in contract {CONTRACT}"),
            })),
        }
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
        if let Opened::Ready { dict, .. } = &opened {
            self.files_of
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .insert(dict.clone(), ids);
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

/// Whether an operation is bulk-class: two at a time.
pub fn is_bulk(op: &str) -> bool {
    matches!(op, "entry" | "resource")
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
