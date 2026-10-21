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
//! **A shell's objects stay on the JavaScript side.** The core needs `Send + Sync` sources and the workspace
//! forbids `unsafe`, so a JavaScript object is never held in Rust: it is kept in a table on this (single)
//! thread and the core holds its number. Three rules keep the tables sound:
//!
//! - **JavaScript never runs while a table is borrowed**: a handle is cloned out first, so a callback may call
//!   back into the binding (register a source, open or import another package).
//! - **Every call into JavaScript catches**: an exception from a callback becomes a typed error, never an
//!   unwind through Rust frames that skips their cleanup. `size()` and `identity()` cannot return an error to
//!   the core, so their exceptions are recorded, and the call they happened in fails with the first ([`watched`]),
//!   leaving nothing behind: an `open` that stored a dictionary closes it again.
//! - **Every entry has owners and goes when the last one does**: a source is owned by the shell's registration
//!   (until `releaseSource`) and by each location the core holds; index storage by its core; a progress
//!   callback by its import.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::sync::Arc;

use serde_json::Value;
use wasm_bindgen::JsCast;
use wasm_bindgen::prelude::*;
use xdict_core as core;
use xdict_core::{CoreError, FileIdentity};

#[wasm_bindgen]
extern "C" {
    /// `{ size(): number, readAt(offset: number, len: number): Uint8Array, identity(): WireIdentity | null }`,
    /// where a wire identity's fields are decimal strings (exact) or numbers (exact below 2^53).
    #[derive(Clone)]
    pub type JsByteSource;
    #[wasm_bindgen(method, catch)]
    fn size(this: &JsByteSource) -> Result<f64, JsValue>;
    #[wasm_bindgen(method, js_name = readAt, catch)]
    fn read_at(this: &JsByteSource, offset: f64, len: u32) -> Result<Vec<u8>, JsValue>;
    #[wasm_bindgen(method, catch)]
    fn identity(this: &JsByteSource) -> Result<JsValue, JsValue>;

    /// `{ get(name: string): ByteSource | null, put(name: string, bytes: Uint8Array): void }`.
    #[derive(Clone)]
    pub type JsIndexStorage;
    #[wasm_bindgen(method, catch)]
    fn get(this: &JsIndexStorage, name: &str) -> Result<JsValue, JsValue>;
    #[wasm_bindgen(method, catch)]
    fn put(this: &JsIndexStorage, name: &str, bytes: Vec<u8>) -> Result<(), JsValue>;

    /// `{ progress(done: number, total: number): boolean }`.
    #[derive(Clone)]
    pub type JsProgress;
    #[wasm_bindgen(method, catch)]
    fn progress(this: &JsProgress, done: f64, total: f64) -> Result<bool, JsValue>;
}

/// JavaScript handles by number, each with the count of its owners.
struct Table<T> {
    next: u32,
    items: HashMap<u32, (T, u32)>,
}

impl<T: Clone> Table<T> {
    fn new() -> Self {
        Self { next: 0, items: HashMap::new() }
    }

    /// A new entry with one owner, the caller, under a number no live entry has (never 0); `None` when every
    /// number is in use. The counter wraps, so a number is found by moving past those still held.
    fn insert(&mut self, item: T) -> Option<u32> {
        if self.items.len() >= u32::MAX as usize {
            return None;
        }
        loop {
            self.next = self.next.wrapping_add(1);
            if self.next != 0 && !self.items.contains_key(&self.next) {
                self.items.insert(self.next, (item, 1));
                return Some(self.next);
            }
        }
    }

    /// One more owner of `id`; false if there is no such entry.
    fn claim(&mut self, id: u32) -> bool {
        self.items.get_mut(&id).map(|(_, owners)| *owners += 1).is_some()
    }

    /// One owner fewer; the entry goes with its last. True if it went.
    fn release(&mut self, id: u32) -> bool {
        match self.items.get_mut(&id) {
            Some((_, owners)) if *owners > 1 => {
                *owners -= 1;
                false
            }
            Some(_) => self.items.remove(&id).is_some(),
            None => false,
        }
    }

    fn get(&self, id: u32) -> Option<T> {
        self.items.get(&id).map(|(item, _)| item.clone())
    }
}

thread_local! {
    static SOURCES: RefCell<Table<JsByteSource>> = RefCell::new(Table::new());
    static STORAGE: RefCell<Table<JsIndexStorage>> = RefCell::new(Table::new());
    static PROGRESS: RefCell<Table<JsProgress>> = RefCell::new(Table::new());
    /// Sources whose `size()` or `identity()` threw: every later read of them fails with this.
    static FAILED: RefCell<HashMap<u32, String>> = RefCell::new(HashMap::new());
    /// The exceptions of `size()` and `identity()` during the outermost call now running, in order ([`watched`]).
    static THROWN: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
    /// How many [`watched`] calls are running: a callback may call back into the binding.
    static DEPTH: Cell<u32> = const { Cell::new(0) };
    /// Resource replies not yet freed.
    static REPLIES: Cell<u32> = const { Cell::new(0) };
}

/// A shell's index storage by its number in [`STORAGE`], owned by its core: it goes when the core does.
struct Storage(u32);

impl Storage {
    fn handle(&self) -> Result<JsIndexStorage, CoreError> {
        STORAGE.with(|table| table.borrow().get(self.0)).ok_or_else(|| CoreError::Io {
            kind: core::IoKind::NotFound,
            detail: "the index storage was released".into(),
        })
    }
}

impl Drop for Storage {
    fn drop(&mut self) {
        STORAGE.with(|table| table.borrow_mut().release(self.0));
    }
}

fn storage_error(what: &str, e: &JsValue) -> CoreError {
    CoreError::Io { kind: core::IoKind::Other, detail: format!("the index storage failed to {what}: {e:?}") }
}

impl core::IndexStorage for Storage {
    fn get(&self, name: &str) -> Result<Option<Arc<dyn core::ByteSource>>, CoreError> {
        let found = self.handle()?.get(name).map_err(|e| storage_error("read", &e))?;
        if found.is_null() || found.is_undefined() {
            return Ok(None);
        }
        Ok(Some(Arc::new(IndexSource(Source::adopt(found.unchecked_into())?))))
    }
    fn put(&self, name: &str, bytes: Vec<u8>) -> Result<(), CoreError> {
        self.handle()?.put(name, bytes).map_err(|e| storage_error("write", &e))
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

/// One owner of a JavaScript source in [`SOURCES`]; the entry goes when its last owner does.
struct Source(u32);

impl Source {
    /// A source of the shell's registration, if it is still registered.
    fn claim(id: u32) -> Option<Source> {
        SOURCES.with(|table| table.borrow_mut().claim(id)).then_some(Source(id))
    }

    /// A source the binding registers itself, with this as its only owner.
    fn adopt(handle: JsByteSource) -> Result<Source, CoreError> {
        SOURCES.with(|table| table.borrow_mut().insert(handle)).map(Source).ok_or_else(|| exhausted("sources"))
    }

    fn handle(&self) -> Option<JsByteSource> {
        SOURCES.with(|table| table.borrow().get(self.0))
    }

    fn fail(&self, what: &str, e: &JsValue) {
        self.failed(format!("the source's {what}() threw: {e:?}"));
    }

    /// Records why this source failed: the call running now fails with it ([`watched`]), and so does every
    /// later read of the source.
    fn failed(&self, why: String) {
        THROWN.with(|thrown| thrown.borrow_mut().push(why.clone()));
        FAILED.with(|failed| failed.borrow_mut().insert(self.0, why));
    }
}

/// Runs a call into the core, and fails it if a source's `size()` or `identity()` threw while it ran: the core
/// saw only what the binding could give in its place (no size, no identity), so whatever it concluded, this is
/// why. A nested call (from a callback) fails with what threw inside it; the outer one sees that too.
fn watched<T>(call: impl FnOnce() -> T) -> (T, Result<(), String>) {
    let mark = THROWN.with(|thrown| thrown.borrow().len());
    DEPTH.with(|depth| depth.set(depth.get() + 1));
    let out = call();
    let depth = DEPTH.with(|depth| {
        depth.set(depth.get().saturating_sub(1));
        depth.get()
    });
    let first = THROWN.with(|thrown| {
        let mut thrown = thrown.borrow_mut();
        let first = thrown.get(mark).cloned();
        if depth == 0 {
            thrown.clear();
        }
        first
    });
    let checked = match first {
        Some(why) => Err(to_json(&CoreError::Io { kind: core::IoKind::Other, detail: why })),
        None => Ok(()),
    };
    (out, checked)
}

impl Drop for Source {
    fn drop(&mut self) {
        release_source(self.0);
    }
}

/// Every number of a table is in use.
fn exhausted(what: &str) -> CoreError {
    CoreError::Io { kind: core::IoKind::OutOfMemory, detail: format!("no number is left for more {what}") }
}

fn gone() -> CoreError {
    CoreError::Io { kind: core::IoKind::NotFound, detail: "the source was released".into() }
}

impl core::ByteSource for Source {
    fn size(&self) -> u64 {
        let Some(handle) = self.handle() else { return 0 };
        handle.size().unwrap_or_else(|e| {
            self.fail("size", &e);
            0.0
        }) as u64
    }
    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        if let Some(why) = FAILED.with(|failed| failed.borrow().get(&self.0).cloned()) {
            return Err(CoreError::Io { kind: core::IoKind::Other, detail: why });
        }
        self.handle()
            .ok_or_else(gone)?
            .read_at(offset as f64, len)
            .map_err(|e| CoreError::Io { kind: core::IoKind::Other, detail: format!("the source failed: {e:?}") })
    }
    fn identity(&self) -> Option<FileIdentity> {
        match self.handle()?.identity().map(|value| identity_from(&value)) {
            Ok(Ok(identity)) => identity,
            Ok(Err(why)) => {
                self.failed(format!("the source's identity() gave no identity a file can have: {why}"));
                None
            }
            Err(e) => {
                self.fail("identity", &e);
                None
            }
        }
    }
}

/// An identity as the wrapper sends it: each field a decimal string (exact) or a number. `None` for null or
/// undefined, a file without one; anything else that is not a whole identity is the shell's mistake, and why.
fn identity_from(value: &JsValue) -> Result<Option<FileIdentity>, String> {
    if value.is_null() || value.is_undefined() {
        return Ok(None);
    }
    let text = stringify(value).map_err(|e| format!("it cannot be read: {e:?}"))?;
    let text = text.as_string().ok_or("it is not an object")?;
    let json: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let field = |name: &str| -> Result<i128, String> {
        let bad = || format!("{name} is not a whole number");
        match json.get(name) {
            Some(Value::String(text)) => text.parse().map_err(|_| bad()),
            Some(Value::Number(n)) => n.as_i64().map(i128::from).or_else(|| n.as_u64().map(i128::from)).ok_or_else(bad),
            _ => Err(bad()),
        }
    };
    let range = |name: &str| format!("{name} is out of range");
    Ok(Some(FileIdentity {
        device: u64::try_from(field("device")?).map_err(|_| range("device"))?,
        inode: u64::try_from(field("inode")?).map_err(|_| range("inode"))?,
        size: u64::try_from(field("size")?).map_err(|_| range("size"))?,
        mtime_ns: i64::try_from(field("mtimeNs")?).map_err(|_| range("mtimeNs"))?,
        ctime_ns: i64::try_from(field("ctimeNs")?).map_err(|_| range("ctimeNs"))?,
    }))
}

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = JSON, catch)]
    fn stringify(value: &JsValue) -> Result<JsValue, JsValue>;
}

/// An import's progress callback, by its number in [`PROGRESS`] (released when the import ends; one that throws
/// cancels the import), and how many exceptions [`THROWN`] held when the import began: once a source has thrown
/// during the import, the answer is `false`, so the core stops before it registers anything (it asks once more
/// just before), and the import fails with the source's exception ([`watched`]). Asked again after the callback,
/// since the callback may call into the core, and a source may throw there.
struct Progress(Option<u32>, usize);

impl core::Progress for Progress {
    fn progress(&self, done: u64, total: u64) -> bool {
        let clean = || THROWN.with(|thrown| thrown.borrow().len()) <= self.1;
        if !clean() {
            return false;
        }
        let Some(id) = self.0 else { return true };
        let go = match PROGRESS.with(|table| table.borrow().get(id)) {
            Some(callback) => callback.progress(done as f64, total as f64).unwrap_or(false),
            None => true,
        };
        go && clean()
    }
}

impl Drop for Progress {
    fn drop(&mut self) {
        if let Some(id) = self.0 {
            PROGRESS.with(|table| table.borrow_mut().release(id));
        }
    }
}

/// Gives up the shell's registration of a source. A dictionary still holding it keeps it until it closes.
#[wasm_bindgen(js_name = releaseSource)]
pub fn release_source(id: u32) {
    if SOURCES.with(|table| table.borrow_mut().release(id)) {
        FAILED.with(|failed| failed.borrow_mut().remove(&id));
    }
}

/// Registers a source; the number goes into a location's JSON as `sourceId`. The shell owns the registration
/// until it calls `releaseSource`.
#[wasm_bindgen(js_name = registerSource)]
pub fn register_source(source: JsByteSource) -> Result<u32, String> {
    SOURCES.with(|table| table.borrow_mut().insert(source)).ok_or_else(|| to_json(&exhausted("sources")))
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

/// How many entries each table holds, and how many resource replies are not yet freed: for the suite, which
/// checks that nothing a call registers outlives its owners.
#[wasm_bindgen(js_name = selfTestTables)]
pub fn self_test_tables() -> String {
    serde_json::json!({
        "sources": SOURCES.with(|t| t.borrow().items.len()),
        "storage": STORAGE.with(|t| t.borrow().items.len()),
        "progress": PROGRESS.with(|t| t.borrow().items.len()),
        "replies": REPLIES.with(Cell::get),
    })
    .to_string()
}

/// A resource: its JSON (without the bytes) and its bytes, taken once. Free it when done.
#[wasm_bindgen]
pub struct ResourceReply {
    json: String,
    bytes: Vec<u8>,
}

impl ResourceReply {
    fn new(json: String, bytes: Vec<u8>) -> Self {
        REPLIES.with(|n| n.set(n.get() + 1));
        Self { json, bytes }
    }
}

impl Drop for ResourceReply {
    fn drop(&mut self) {
        REPLIES.with(|n| n.set(n.get().saturating_sub(1)));
    }
}

#[wasm_bindgen]
impl ResourceReply {
    #[wasm_bindgen(getter)]
    pub fn json(&self) -> String {
        self.json.clone()
    }
    /// The bytes, moved out rather than copied; a second call gets none.
    #[wasm_bindgen(js_name = takeBytes)]
    pub fn take_bytes(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.bytes)
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
                let id = STORAGE.with(|table| table.borrow_mut().insert(storage));
                let storage = Storage(id.ok_or_else(|| to_json(&exhausted("index storages")))?);
                core::Core::with_index_storage(config, Arc::new(storage))
            }
            None => core::Core::new(config),
        };
        made.map(Core).map_err(|e| to_json(&e))
    }

    pub fn import(&self, package: &str, progress: Option<JsProgress>) -> Reply {
        let package = package_from(&from_json::<Value>(package)?)?;
        let progress = match progress {
            Some(p) => Some(
                PROGRESS.with(|table| table.borrow_mut().insert(p)).ok_or_else(|| to_json(&exhausted("imports")))?,
            ),
            None => None,
        };
        let progress = Progress(progress, THROWN.with(|thrown| thrown.borrow().len()));
        watched_reply(|| self.0.import(package, &progress))
    }

    /// All or nothing: a dictionary opened while one of its sources threw is closed again before the error.
    pub fn open(&self, package: &str) -> Reply {
        let package = package_from(&from_json::<Value>(package)?)?;
        let (result, checked) = watched(|| self.0.open(package));
        if let Err(why) = checked {
            if let Ok(core::Opened::Ready { dict, .. }) = result {
                let _ = self.0.close(dict);
            }
            return Err(why);
        }
        reply(result)
    }

    pub fn close(&self, dict: &str) -> Reply {
        reply(self.0.close(dict.into()).map(|()| Value::Null))
    }

    pub fn lookup(&self, query: &str, dicts: &str, options: &str) -> Reply {
        let (dicts, options) = (from_json(dicts)?, from_json(options)?);
        watched_reply(|| self.0.lookup(query.into(), dicts, options))
    }

    pub fn suggest(&self, prefix: &str, dicts: &str, limit: u32) -> Reply {
        let dicts = from_json(dicts)?;
        watched_reply(|| self.0.suggest(prefix.into(), dicts, limit))
    }

    pub fn entry(&self, dict: &str, entry: &str, view: &str) -> Reply {
        let (entry, view) = (from_json(entry)?, from_json(view)?);
        watched_reply(|| self.0.entry(dict.into(), entry, view))
    }

    /// The whole entry as plain text (ADR-0021 d.5): spans, completeness and the budget's cut.
    pub fn entry_text(&self, dict: &str, entry: &str, view: &str) -> Reply {
        let (entry, view) = (from_json(entry)?, from_json(view)?);
        watched_reply(|| self.0.entry_text(dict.into(), entry, view))
    }

    /// **Records a reading** in the local history (ADR-0023). `reading` is a `Reading` as JSON; `targetLanguages` is a
    /// JSON array of the languages the reader keeps. The answer is the outcome's JSON: `"recorded"`, `"duplicate"`,
    /// `"uncertain"` or `"skippedLanguage"`. The Web's log lives in memory until its worker adapter lands (ADR-0024).
    pub fn ledger_record(&self, reading: &str, operation: &str, target_languages: &str) -> Reply {
        let reading = from_json(reading)?;
        let target_languages = from_json(target_languages)?;
        watched_reply(|| self.0.ledger_record(reading, operation.to_string(), target_languages))
    }

    /// **Saves the reader's note on an entry** (plan §5.1). `stamp` is `{ at, device }` as JSON; the answer is the note.
    pub fn study_note(&self, dict: &str, entry: &str, text: &str, name: &str, stamp: &str, operation: &str) -> Reply {
        let (entry, stamp) = (from_json(entry)?, from_json(stamp)?);
        watched_reply(|| self.0.study_note(dict.into(), entry, text.into(), name.into(), stamp, operation.into()))
    }

    pub fn study_notes(&self) -> Reply {
        watched_reply(|| self.0.study_notes())
    }

    /// The review queue: due cards, soonest first, a new card at once.
    pub fn review_queue(&self, now: f64, limit: u32) -> Reply {
        watched_reply(|| self.0.review_queue(now, limit))
    }

    /// One grade under the reader's configuration; `policy` and `stamp` are JSON.
    pub fn review_grade(
        &self,
        target_key: &str,
        revision: &str,
        grade: u8,
        policy: &str,
        stamp: &str,
        operation: &str,
    ) -> Reply {
        let (policy, stamp) = (from_json(policy)?, from_json(stamp)?);
        watched_reply(|| {
            self.0.review_grade(target_key.into(), revision.into(), grade, policy, stamp, operation.into())
        })
    }

    pub fn review_undo(&self, target_key: &str, grade_event: &str, stamp: &str, operation: &str) -> Reply {
        let stamp = from_json(stamp)?;
        watched_reply(|| self.0.review_undo(target_key.into(), grade_event.into(), stamp, operation.into()))
    }

    pub fn review_summary(&self, now: f64) -> Reply {
        watched_reply(|| self.0.review_summary(now))
    }

    pub fn definition_hash_of(&self, dict: &str, entry: &str) -> Reply {
        let entry = from_json(entry)?;
        watched_reply(|| self.0.definition_hash_of(dict.into(), entry))
    }

    pub fn study_reanchor(&self, old_edition: &str, new_edition: &str, stamp: &str, operation_prefix: &str) -> Reply {
        let stamp = from_json(stamp)?;
        watched_reply(|| self.0.study_reanchor(old_edition.into(), new_edition.into(), stamp, operation_prefix.into()))
    }

    /// The days the drawer shows, in the reader's own zone: `utcOffsetSeconds` east of UTC while `now` is the clock.
    pub fn ledger_history(&self, now: f64, utc_offset_seconds: i32) -> Reply {
        watched_reply(|| self.0.ledger_history(now, utc_offset_seconds))
    }

    pub fn link(&self, dict: &str, url: &str, origin: &str, view: &str) -> Reply {
        reply(self.0.link(dict.into(), url.into(), from_json(origin)?, from_json(view)?))
    }

    pub fn resource(&self, dict: &str, path: &str, view: &str) -> Result<ResourceReply, String> {
        let view = from_json(view)?;
        let (result, checked) = watched(|| self.0.resource(dict.into(), path.into(), view));
        checked?;
        match result {
            Ok(core::Resource::Found { path, mime, bytes }) => {
                let json = serde_json::json!({ "type": "found", "path": path, "mime": mime }).to_string();
                Ok(ResourceReply::new(json, bytes))
            }
            Ok(missing) => Ok(ResourceReply::new(to_json(&missing), Vec::new())),
            Err(e) => Err(to_json(&e)),
        }
    }

    /// The edition's health report (WI-12): checked once and kept with its indexes; `progress` as for an import.
    pub fn health(&self, dict: &str, progress: Option<JsProgress>) -> Reply {
        let progress = match progress {
            Some(p) => {
                Some(PROGRESS.with(|table| table.borrow_mut().insert(p)).ok_or_else(|| to_json(&exhausted("checks")))?)
            }
            None => None,
        };
        let progress = Progress(progress, THROWN.with(|thrown| thrown.borrow().len()));
        watched_reply(|| self.0.health(dict.into(), &progress))
    }

    /// The display options that apply to an open dictionary, with its defaults, and their CSS (ADR-0013). Reads a
    /// sample of the edition's records, so through its sources.
    #[wasm_bindgen(js_name = displayOptions)]
    pub fn display_options(&self, dict: &str) -> Reply {
        watched_reply(|| self.0.display_options(dict.into()))
    }

    #[wasm_bindgen(js_name = joinLineage)]
    pub fn join_lineage(&self, edition: &str, lineage: &str) -> Reply {
        reply(self.0.join_lineage(edition.into(), lineage.into()))
    }

    #[wasm_bindgen(js_name = splitLineage)]
    pub fn split_lineage(&self, edition: &str, new_lineage: &str) -> Reply {
        reply(self.0.split_lineage(edition.into(), new_lineage.into()))
    }

    #[wasm_bindgen(js_name = lineageOf)]
    pub fn lineage_of(&self, edition: &str) -> Reply {
        reply(self.0.lineage_of(edition.into()))
    }

    #[wasm_bindgen(js_name = selfTestPanic)]
    pub fn self_test_panic(&self) -> Reply {
        reply(self.0.self_test_panic().map(|()| Value::Null))
    }
}

/// A call into the core, [`watched`]: the error of a source that threw while it ran, else its own answer.
fn watched_reply<T: serde::Serialize>(call: impl FnOnce() -> Result<T, CoreError>) -> Reply {
    let (result, checked) = watched(call);
    checked?;
    reply(result)
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

fn malformed(what: &str, why: &str) -> String {
    to_json(&CoreError::Malformed { detail: format!("{what}: {why}") })
}

/// `{"type":"path","path":…}` or `{"type":"source","name":…,"sourceId":…}`.
fn location_from(value: &Value) -> Result<core::Location, String> {
    let bad = |why: &str| malformed("a location", why);
    match value["type"].as_str() {
        Some("path") => Ok(core::Location::Path { path: value["path"].as_str().ok_or_else(|| bad("no path"))?.into() }),
        Some("source") => {
            let id =
                value["sourceId"].as_u64().and_then(|n| u32::try_from(n).ok()).ok_or_else(|| bad("no sourceId"))?;
            let name = value["name"].as_str().ok_or_else(|| bad("no name"))?.into();
            let source = Source::claim(id).ok_or_else(|| bad("an unregistered sourceId"))?;
            Ok(core::Location::Source { name, source: Arc::new(source) })
        }
        _ => Err(bad("no type")),
    }
}

/// A package; `mdd` and `sidecars` may be left out, but when present each must be a list (`null` is not one: the
/// wrapper always sends a list, so a null is a mistake, not "none").
fn package_from(value: &Value) -> Result<core::Package, String> {
    let list = |key: &str| -> Result<Vec<core::Location>, String> {
        match value.get(key) {
            None => Ok(Vec::new()),
            Some(Value::Array(items)) => items.iter().map(location_from).collect(),
            Some(other) => Err(malformed("a package", &format!("{key} is {other}, not a list"))),
        }
    };
    Ok(core::Package { mdx: location_from(&value["mdx"])?, mdd: list("mdd")?, sidecars: list("sidecars")? })
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    /// A number still in use is never handed out again: when the counter wraps, the new entry takes a free one.
    #[test]
    fn a_wrapped_handle_never_replaces_a_live_one() {
        let mut table = Table::new();
        let first = table.insert('a').unwrap();
        table.next = u32::MAX - 1;
        let later: Vec<u32> = ['b', 'c', 'd'].into_iter().map(|item| table.insert(item).unwrap()).collect();
        assert_eq!(table.get(first), Some('a'));
        assert!(!later.contains(&first) && !later.contains(&0), "{later:?}");
        assert_eq!(later.iter().map(|&id| table.get(id).unwrap()).collect::<String>(), "bcd");
    }

    #[test]
    fn a_package_list_that_is_not_a_list_is_refused() {
        let mdx = serde_json::json!({ "type": "path", "path": "a.mdx" });
        // `null` too: the wrapper always sends a list, so a null is a shell's mistake, not "none".
        for bad in [
            serde_json::json!(5),
            serde_json::json!("a.mdd"),
            serde_json::json!({ "type": "path" }),
            serde_json::json!(null),
        ] {
            for key in ["mdd", "sidecars"] {
                let mut fields = serde_json::Map::new();
                fields.insert("mdx".into(), mdx.clone());
                fields.insert(key.into(), bad.clone());
                let package = Value::Object(fields);
                let error = package_from(&package).err().unwrap_or_default();
                assert!(error.contains("malformed") && error.contains(key), "{key} = {bad}: {error}");
            }
        }
        let absent = package_from(&serde_json::json!({ "mdx": mdx })).map(|p| (p.mdd.len(), p.sidecars.len()));
        assert_eq!(absent, Ok((0, 0)));
    }

    #[test]
    fn a_table_entry_goes_with_its_last_owner() {
        let mut table = Table::new();
        let id = table.insert("source").unwrap();
        assert!(table.claim(id));
        assert!(!table.release(id), "one owner is left");
        assert_eq!(table.get(id), Some("source"));
        assert!(table.release(id), "the last owner takes it");
        assert_eq!(table.get(id), None);
        assert!(!table.claim(id), "a released entry cannot be claimed");
    }
}
