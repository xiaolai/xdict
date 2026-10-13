//! `wasm-bindgen` bindings of `xdict-core` for the Web, run in a Worker.
//!
//! **Message-shaped**: every call takes and returns JSON in the serde shape of the core's types (camel-case
//! fields, a `type` tag); a failure is thrown as the JSON of a `CoreError`. Only a resource's bytes travel
//! outside JSON. `ts/xdict.ts` is the typed wrapper a shell uses.
//!
//! **A panic is a trap here**, not a value: `catch_unwind` does not catch it under `wasm32-unknown-unknown`
//! (measured, ADR-0007 decision 12). It reaches JavaScript as a `RuntimeError`; the wrapper reports it as
//! `internal` and the instance must be replaced.
//!
//! **A shell's byte source stays on the JavaScript side.** The core needs `Send + Sync` sources and the
//! workspace forbids `unsafe`, so a JavaScript object is never held in Rust: it is kept in a table on this
//! (single) thread and the core holds its number.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use serde_json::Value;
use wasm_bindgen::JsCast;
use wasm_bindgen::prelude::*;
use xdict_core as core;
use xdict_core::{CoreError, FileIdentity};

#[wasm_bindgen]
extern "C" {
    /// `{ size(): number, readAt(offset: number, len: number): Uint8Array, identity(): FileIdentity | null }`.
    pub type JsByteSource;
    #[wasm_bindgen(method)]
    fn size(this: &JsByteSource) -> f64;
    #[wasm_bindgen(method, js_name = readAt, catch)]
    fn read_at(this: &JsByteSource, offset: f64, len: u32) -> Result<Vec<u8>, JsValue>;
    #[wasm_bindgen(method)]
    fn identity(this: &JsByteSource) -> JsValue;

    /// `{ get(name: string): ByteSource | null, put(name: string, bytes: Uint8Array): void }`.
    pub type JsIndexStorage;
    #[wasm_bindgen(method, catch)]
    fn get(this: &JsIndexStorage, name: &str) -> Result<JsValue, JsValue>;
    #[wasm_bindgen(method, catch)]
    fn put(this: &JsIndexStorage, name: &str, bytes: Vec<u8>) -> Result<(), JsValue>;

    /// `{ progress(done: number, total: number): boolean }`.
    pub type JsProgress;
    #[wasm_bindgen(method)]
    fn progress(this: &JsProgress, done: f64, total: f64) -> bool;
}

thread_local! {
    static SOURCES: RefCell<(u32, HashMap<u32, JsByteSource>)> = RefCell::new((0, HashMap::new()));
    static STORAGE: RefCell<(u32, HashMap<u32, JsIndexStorage>)> = RefCell::new((0, HashMap::new()));
}

/// A shell's index storage by its number in [`STORAGE`], kept on this thread for the same reason as sources.
struct Storage(u32);

impl Storage {
    fn with<T>(&self, call: impl FnOnce(&JsIndexStorage) -> T) -> Result<T, CoreError> {
        STORAGE.with(|table| table.borrow().1.get(&self.0).map(call)).ok_or_else(|| CoreError::Io {
            kind: core::IoKind::NotFound,
            detail: "the index storage was released".into(),
        })
    }
}

fn storage_error(what: &str, e: &JsValue) -> CoreError {
    CoreError::Io { kind: core::IoKind::Other, detail: format!("the index storage failed to {what}: {e:?}") }
}

impl core::IndexStorage for Storage {
    fn get(&self, name: &str) -> Result<Option<Arc<dyn core::ByteSource>>, CoreError> {
        let found = self.with(|s| s.get(name))?.map_err(|e| storage_error("read", &e))?;
        if found.is_null() || found.is_undefined() {
            return Ok(None);
        }
        let id = register_source(found.unchecked_into());
        Ok(Some(Arc::new(IndexSource(Source(id)))))
    }
    fn put(&self, name: &str, bytes: Vec<u8>) -> Result<(), CoreError> {
        self.with(|s| s.put(name, bytes))?.map_err(|e| storage_error("write", &e))
    }
}

/// An index's source, registered for this one use and released with it.
struct IndexSource(Source);

impl core::ByteSource for IndexSource {
    fn size(&self) -> u64 {
        self.0.size()
    }
    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        self.0.read_at(offset, len)
    }
    fn identity(&self) -> Option<FileIdentity> {
        None
    }
}

impl Drop for IndexSource {
    fn drop(&mut self) {
        release_source(self.0.0);
    }
}

/// A JavaScript source by its number in [`SOURCES`]. It stays in the table until the shell releases it:
/// several locations, and the registry, may name one source.
struct Source(u32);

impl Source {
    fn with<T>(&self, call: impl FnOnce(&JsByteSource) -> T) -> Option<T> {
        SOURCES.with(|table| table.borrow().1.get(&self.0).map(call))
    }
}

fn gone() -> CoreError {
    CoreError::Io { kind: core::IoKind::NotFound, detail: "the source was released".into() }
}

impl core::ByteSource for Source {
    fn size(&self) -> u64 {
        self.with(|s| s.size()).unwrap_or(0.0) as u64
    }
    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        self.with(|s| s.read_at(offset as f64, len))
            .ok_or_else(gone)?
            .map_err(|e| CoreError::Io { kind: core::IoKind::Other, detail: format!("the source failed: {e:?}") })
    }
    fn identity(&self) -> Option<FileIdentity> {
        let value = self.with(|s| s.identity())?;
        let json = js_sys_json(&value)?;
        serde_json::from_str(&json).ok()
    }
}

/// A plain object as JSON text, through the host's `JSON.stringify`.
fn js_sys_json(value: &JsValue) -> Option<String> {
    if value.is_null() || value.is_undefined() {
        return None;
    }
    stringify(value).ok().and_then(|s| s.as_string())
}

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = JSON, catch)]
    fn stringify(value: &JsValue) -> Result<JsValue, JsValue>;
}

struct Progress(JsProgress);

impl core::Progress for ProgressRef {
    fn progress(&self, done: u64, total: u64) -> bool {
        PROGRESS.with(|slot| slot.borrow().as_ref().is_none_or(|p| p.0.progress(done as f64, total as f64)))
    }
}

thread_local! {
    static PROGRESS: RefCell<Option<Progress>> = const { RefCell::new(None) };
}

/// The progress callback of the import running now, held in [`PROGRESS`] for its duration.
struct ProgressRef;

/// Forgets a source. A dictionary still reading it gets an I/O error.
#[wasm_bindgen(js_name = releaseSource)]
pub fn release_source(id: u32) {
    SOURCES.with(|table| table.borrow_mut().1.remove(&id));
}

/// Registers a source; the number goes into a location's JSON as `sourceId`.
#[wasm_bindgen(js_name = registerSource)]
pub fn register_source(source: JsByteSource) -> u32 {
    SOURCES.with(|table| {
        let mut table = table.borrow_mut();
        table.0 = table.0.wrapping_add(1);
        let id = table.0;
        table.1.insert(id, source);
        id
    })
}

#[wasm_bindgen(js_name = versions)]
pub fn versions() -> String {
    to_json(&core::Core::versions())
}

#[wasm_bindgen(js_name = protocolVersion)]
pub fn protocol_version() -> u32 {
    core::PROTOCOL
}

/// Panics outside the core's guard, to show what a panic becomes here: a trap.
#[wasm_bindgen(js_name = selfTestTrap)]
pub fn self_test_trap() {
    #[allow(clippy::panic)]
    {
        panic!("the deliberate trap of selfTestTrap")
    }
}

/// A resource: its JSON (without the bytes) and its bytes.
#[wasm_bindgen]
pub struct ResourceReply {
    json: String,
    bytes: Vec<u8>,
}

#[wasm_bindgen]
impl ResourceReply {
    #[wasm_bindgen(getter)]
    pub fn json(&self) -> String {
        self.json.clone()
    }
    #[wasm_bindgen(getter)]
    pub fn bytes(&self) -> Vec<u8> {
        self.bytes.clone()
    }
}

#[wasm_bindgen]
pub struct Core(core::Core);

type Reply = Result<String, String>;

#[wasm_bindgen]
impl Core {
    /// `config`: a `Config` as JSON; `entropy` must hold random bytes (the core has no random source here).
    /// `storage` keeps the indexes (the origin-private file system); without it they live in memory.
    #[wasm_bindgen(constructor)]
    pub fn new(config: &str, storage: Option<JsIndexStorage>) -> Result<Core, String> {
        let config: core::Config = from_json(config)?;
        let made = match storage {
            Some(storage) => {
                let id = STORAGE.with(|table| {
                    let mut table = table.borrow_mut();
                    table.0 = table.0.wrapping_add(1);
                    let id = table.0;
                    table.1.insert(id, storage);
                    id
                });
                core::Core::with_index_storage(config, Arc::new(Storage(id)))
            }
            None => core::Core::new(config),
        };
        made.map(Core).map_err(|e| to_json(&e))
    }

    pub fn import(&self, package: &str, progress: Option<JsProgress>) -> Reply {
        let package = package_from(&from_json::<Value>(package)?)?;
        PROGRESS.with(|slot| *slot.borrow_mut() = progress.map(Progress));
        let result = self.0.import(package, &ProgressRef);
        PROGRESS.with(|slot| *slot.borrow_mut() = None);
        reply(result)
    }

    pub fn open(&self, package: &str) -> Reply {
        reply(self.0.open(package_from(&from_json::<Value>(package)?)?))
    }

    pub fn close(&self, dict: &str) -> Reply {
        reply(self.0.close(dict.into()).map(|()| Value::Null))
    }

    pub fn lookup(&self, query: &str, dicts: &str, options: &str) -> Reply {
        reply(self.0.lookup(query.into(), from_json(dicts)?, from_json(options)?))
    }

    pub fn suggest(&self, prefix: &str, dicts: &str, limit: u32) -> Reply {
        reply(self.0.suggest(prefix.into(), from_json(dicts)?, limit))
    }

    pub fn entry(&self, dict: &str, entry: &str, view: &str) -> Reply {
        reply(self.0.entry(dict.into(), from_json(entry)?, from_json(view)?))
    }

    pub fn link(&self, dict: &str, url: &str, origin: &str, view: &str) -> Reply {
        reply(self.0.link(dict.into(), url.into(), from_json(origin)?, from_json(view)?))
    }

    pub fn resource(&self, dict: &str, path: &str, view: &str) -> Result<ResourceReply, String> {
        match self.0.resource(dict.into(), path.into(), from_json(view)?) {
            Ok(core::Resource::Found { path, mime, bytes }) => {
                let json = serde_json::json!({ "type": "found", "path": path, "mime": mime }).to_string();
                Ok(ResourceReply { json, bytes })
            }
            Ok(missing) => Ok(ResourceReply { json: to_json(&missing), bytes: Vec::new() }),
            Err(e) => Err(to_json(&e)),
        }
    }

    #[wasm_bindgen(js_name = selfTestPanic)]
    pub fn self_test_panic(&self) -> Reply {
        reply(self.0.self_test_panic().map(|()| Value::Null))
    }
}

fn reply<T: serde::Serialize>(result: Result<T, CoreError>) -> Reply {
    result.map(|v| to_json(&v)).map_err(|e| to_json(&e))
}

fn to_json<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_string(value).unwrap_or_else(|e| {
        format!(r#"{{"type":"internal","detail":{}}}"#, Value::String(format!("unserialisable: {e}")))
    })
}

/// A request that does not parse is the shell's mistake, reported as a `CoreError` like any other.
fn from_json<T: serde::de::DeserializeOwned>(text: &str) -> Result<T, String> {
    serde_json::from_str(text).map_err(|e| to_json(&CoreError::Malformed { detail: format!("a request: {e}") }))
}

/// `{"type":"path","path":…}` or `{"type":"source","name":…,"sourceId":…}`.
fn location_from(value: &Value) -> Result<core::Location, String> {
    let bad = |why: &str| to_json(&CoreError::Malformed { detail: format!("a location: {why}") });
    match value["type"].as_str() {
        Some("path") => Ok(core::Location::Path { path: value["path"].as_str().ok_or_else(|| bad("no path"))?.into() }),
        Some("source") => {
            let id =
                value["sourceId"].as_u64().and_then(|n| u32::try_from(n).ok()).ok_or_else(|| bad("no sourceId"))?;
            if SOURCES.with(|t| !t.borrow().1.contains_key(&id)) {
                return Err(bad("an unregistered sourceId"));
            }
            let name = value["name"].as_str().ok_or_else(|| bad("no name"))?.into();
            Ok(core::Location::Source { name, source: Arc::new(Source(id)) })
        }
        _ => Err(bad("no type")),
    }
}

fn package_from(value: &Value) -> Result<core::Package, String> {
    let list = |key: &str| -> Result<Vec<core::Location>, String> {
        value[key].as_array().map_or(Ok(Vec::new()), |items| items.iter().map(location_from).collect())
    };
    Ok(core::Package { mdx: location_from(&value["mdx"])?, mdd: list("mdd")?, sidecars: list("sidecars")? })
}
