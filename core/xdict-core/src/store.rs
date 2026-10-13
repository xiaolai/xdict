//! Where per-edition indexes are kept (ADR-0007 decision 5): derived, disposable, never synced. Natively a
//! directory of files, written to a temporary name and renamed, and mapped when read; elsewhere in memory, or
//! whatever the shell supplies.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use xdict_mdx::index::{Region, Slice, SourceRegion};

use crate::{ByteSource, CoreError};

/// Index storage a shell supplies where the core has no file system of its own: the Web's origin-private
/// files, read through `FileSystemSyncAccessHandle`. Indexes come back as sources and are read piece by
/// piece, never whole (`core-api.md` §2.3).
pub trait IndexStorage: Send + Sync {
    /// The index stored under `name`, or `None`.
    fn get(&self, name: &str) -> Result<Option<Arc<dyn ByteSource>>, CoreError>;
    /// Stores an index whole, replacing any under that name: a later `get` sees all of it or none.
    fn put(&self, name: &str, bytes: Vec<u8>) -> Result<(), CoreError>;
}

/// A shell's storage as the core's store.
pub(crate) struct Shell(pub(crate) Arc<dyn IndexStorage>);

impl IndexStore for Shell {
    fn get(&self, name: &str) -> Result<Option<Box<dyn Region>>, CoreError> {
        Ok(self.0.get(name)?.map(|source| Box::new(SourceRegion(crate::source::adapt(source))) as Box<dyn Region>))
    }
    fn put(&self, name: &str, bytes: &[u8]) -> Result<(), CoreError> {
        self.0.put(name, bytes.to_vec())
    }
}

pub(crate) trait IndexStore: Send + Sync {
    /// The index stored under `name`, or `None`.
    fn get(&self, name: &str) -> Result<Option<Box<dyn Region>>, CoreError>;
    /// Stores an index whole: a reader sees the old one or the new one, never part of either.
    fn put(&self, name: &str, bytes: &[u8]) -> Result<(), CoreError>;
}

/// Indexes in memory, for tests and for platforms that keep none.
#[derive(Default)]
pub(crate) struct Memory(Mutex<HashMap<String, Arc<Vec<u8>>>>);

/// A shared buffer as a region.
struct Shared(Arc<Vec<u8>>);

impl AsRef<[u8]> for Shared {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}

impl IndexStore for Memory {
    fn get(&self, name: &str) -> Result<Option<Box<dyn Region>>, CoreError> {
        let map = self.0.lock().map_err(|_| CoreError::internal("the index store was poisoned"))?;
        Ok(map.get(name).map(|bytes| Box::new(Slice(Shared(bytes.clone()))) as Box<dyn Region>))
    }
    fn put(&self, name: &str, bytes: &[u8]) -> Result<(), CoreError> {
        let mut map = self.0.lock().map_err(|_| CoreError::internal("the index store was poisoned"))?;
        map.insert(name.to_owned(), Arc::new(bytes.to_vec()));
        Ok(())
    }
}

/// Indexes as files in a directory the core alone writes.
#[cfg(not(target_family = "wasm"))]
pub(crate) struct Directory(pub(crate) std::path::PathBuf);

#[cfg(not(target_family = "wasm"))]
impl IndexStore for Directory {
    fn get(&self, name: &str) -> Result<Option<Box<dyn Region>>, CoreError> {
        match xdict_mmap::Mapped::open(&self.0.join(name)) {
            Ok(mapped) => Ok(Some(Box::new(Slice(mapped)))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            // An empty or unreadable index is one to build again, as a damaged one is.
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => Ok(None),
            Err(e) => Err(CoreError::io(&e)),
        }
    }

    fn put(&self, name: &str, bytes: &[u8]) -> Result<(), CoreError> {
        use std::io::Write;
        std::fs::create_dir_all(&self.0).map_err(|e| CoreError::io(&e))?;
        // A unique temporary name in the same directory, so the rename is atomic and two imports of one
        // edition at once do not write into each other's file.
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let temporary = self.0.join(format!(".{name}.{}.{n}.tmp", std::process::id()));
        let written = (|| {
            let mut file = std::fs::File::create(&temporary)?;
            file.write_all(bytes)?;
            file.sync_all()?;
            std::fs::rename(&temporary, self.0.join(name))
        })();
        if written.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        written.map_err(|e| CoreError::io(&e))
    }
}
