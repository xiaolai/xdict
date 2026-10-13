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

/// Indexes as files in a directory the core alone writes and maps (`xdict_mmap::OwnDirectory`).
#[cfg(not(target_family = "wasm"))]
pub(crate) struct Directory(pub(crate) xdict_mmap::OwnDirectory);

#[cfg(not(target_family = "wasm"))]
impl IndexStore for Directory {
    fn get(&self, name: &str) -> Result<Option<Box<dyn Region>>, CoreError> {
        use std::io::ErrorKind;
        match self.0.map(name) {
            Ok(mapped) => Ok(Some(Box::new(Slice(mapped)))),
            // An absent, empty or foreign index is one to build again, as a damaged one is; writing it replaces
            // whatever was under its name.
            Err(e) if matches!(e.kind(), ErrorKind::NotFound | ErrorKind::UnexpectedEof | ErrorKind::InvalidData) => {
                Ok(None)
            }
            Err(e) => Err(CoreError::io(&e)),
        }
    }

    fn put(&self, name: &str, bytes: &[u8]) -> Result<(), CoreError> {
        // Not synced: an index is disposable and checksummed, so one a crash left short or zeroed is `Stale`
        // when loaded and built again. The registry, the reader's data, is synced.
        self.0.replace(name, bytes).map_err(|e| CoreError::io(&e))
    }
}
