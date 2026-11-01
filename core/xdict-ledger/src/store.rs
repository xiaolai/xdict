//! **Where the log's bytes live** (ADR-0024): the core owns the framing, the replay and the rules; a shell supplies only
//! this port. The log has one writer, a snapshot cache sits beside it, and every method is synchronous because every
//! platform's durable store can be reached synchronously from the worker the core runs in (the Web's origin-private
//! file system through a sync access handle; iOS through its own directory). A binding whose platform store is async
//! adapts it behind this port in its own worker.

use std::sync::Mutex;

#[cfg(not(target_family = "wasm"))]
use std::io::{Read, Seek, SeekFrom, Write};

#[cfg(not(target_family = "wasm"))]
use fs2::FileExt;

use crate::LedgerError;

/// Where the log's bytes live, and the snapshot cache beside them.
pub trait Store: Send + Sync {
    fn load(&self) -> Result<Vec<u8>, LedgerError>;
    fn append(&self, bytes: &[u8]) -> Result<(), LedgerError>;
    fn sync(&self) -> Result<(), LedgerError>;
    fn truncate(&self, length: u64) -> Result<(), LedgerError>;
    fn rewrite(&self, bytes: &[u8]) -> Result<(), LedgerError>;

    /// The projection cache (ADR-0024): `None` when the store has nowhere to put one. A snapshot is a frame, so a torn
    /// one is recognised and discarded rather than trusted.
    fn load_snapshot(&self) -> Result<Option<Vec<u8>>, LedgerError> {
        Ok(None)
    }

    fn save_snapshot(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        let _ = bytes;
        Ok(())
    }
}

/// A file, with the writer lock held for the life of the store.
#[cfg(not(target_family = "wasm"))]
pub struct FileStore {
    file: Mutex<std::fs::File>,
    lock: std::fs::File,
    snapshot: std::path::PathBuf,
}

#[cfg(not(target_family = "wasm"))]
impl FileStore {
    /// Opens the log's file and takes the writer lock beside it. A second writer is refused, not queued.
    pub fn open(path: &std::path::Path) -> Result<Self, LedgerError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|error| refused("the log's folder", error))?;
        }
        let lock_path = path.with_extension("lock");
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&lock_path)
            .map_err(|error| refused("the writer lock", error))?;
        lock.try_lock_exclusive().map_err(|_| LedgerError::Busy)?;
        // **Append by seeking, not `append(true)`**: on Windows an append handle carries `FILE_APPEND_DATA`, and
        // `set_len` (erase's rewrite) is denied without `FILE_WRITE_DATA`. One writer under the lock makes an explicit
        // end-seek equivalent, and every platform's handle can then truncate.
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .map_err(|error| refused("the log", error))?;
        Ok(FileStore { file: Mutex::new(file), lock, snapshot: path.with_extension("snapshot") })
    }
}

/// A store failure that names the call, so a log says which file operation the platform refused.
#[cfg(not(target_family = "wasm"))]
fn refused(what: &str, error: impl std::fmt::Display) -> LedgerError {
    LedgerError::Storage(format!("{what}: {error}"))
}

#[cfg(not(target_family = "wasm"))]
impl Store for FileStore {
    fn load(&self) -> Result<Vec<u8>, LedgerError> {
        let mut file = self.file.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        file.seek(SeekFrom::Start(0)).map_err(|error| refused("seeking the log", error))?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).map_err(|error| refused("reading the log", error))?;
        Ok(bytes)
    }

    fn append(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        let mut file = self.file.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        file.seek(SeekFrom::End(0)).map_err(|error| refused("seeking the log's end", error))?;
        file.write_all(bytes).map_err(|error| refused("appending to the log", error))
    }

    fn sync(&self) -> Result<(), LedgerError> {
        let file = self.file.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        file.sync_all().map_err(|error| refused("syncing the log", error))
    }

    fn truncate(&self, length: u64) -> Result<(), LedgerError> {
        let file = self.file.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        file.set_len(length).map_err(|error| refused("truncating the log", error))
    }

    fn rewrite(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        let mut file = self.file.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        file.set_len(0).map_err(|error| refused("emptying the log for its rewrite", error))?;
        file.seek(SeekFrom::Start(0)).map_err(|error| refused("seeking the log for its rewrite", error))?;
        file.write_all(bytes).map_err(|error| refused("rewriting the log", error))?;
        file.sync_all().map_err(|error| refused("syncing the rewritten log", error))
    }

    fn load_snapshot(&self) -> Result<Option<Vec<u8>>, LedgerError> {
        match std::fs::read(&self.snapshot) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(refused("reading the snapshot", error)),
        }
    }

    /// Written beside the log and renamed over the old one: a reader sees the old snapshot or the new, never a torn one.
    fn save_snapshot(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        let temporary = self.snapshot.with_extension("snapshot.tmp");
        {
            let mut file =
                std::fs::File::create(&temporary).map_err(|error| refused("creating the snapshot", error))?;
            file.write_all(bytes).map_err(|error| refused("writing the snapshot", error))?;
            file.sync_all().map_err(|error| refused("syncing the snapshot", error))?;
        }
        std::fs::rename(&temporary, &self.snapshot).map_err(|error| refused("installing the snapshot", error))
    }
}

#[cfg(not(target_family = "wasm"))]
impl Drop for FileStore {
    fn drop(&mut self) {
        let _ = self.lock.unlock();
    }
}

/// The log in memory: the tests' store, and the Web's until its worker adapter lands (ADR-0024).
#[derive(Default)]
pub struct MemoryStore {
    bytes: Mutex<Vec<u8>>,
    snapshot: Mutex<Option<Vec<u8>>>,
}

impl Store for MemoryStore {
    fn load(&self) -> Result<Vec<u8>, LedgerError> {
        Ok(self.bytes.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?.clone())
    }

    fn append(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        self.bytes.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?.extend_from_slice(bytes);
        Ok(())
    }

    fn sync(&self) -> Result<(), LedgerError> {
        Ok(())
    }

    fn truncate(&self, length: u64) -> Result<(), LedgerError> {
        let mut bytes = self.bytes.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        bytes.truncate(length as usize);
        Ok(())
    }

    fn rewrite(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        let mut held = self.bytes.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        held.clear();
        held.extend_from_slice(bytes);
        Ok(())
    }

    fn load_snapshot(&self) -> Result<Option<Vec<u8>>, LedgerError> {
        Ok(self.snapshot.lock().map_err(|_| LedgerError::Storage("the snapshot is poisoned".into()))?.clone())
    }

    fn save_snapshot(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        *self.snapshot.lock().map_err(|_| LedgerError::Storage("the snapshot is poisoned".into()))? =
            Some(bytes.to_vec());
        Ok(())
    }
}

#[cfg(all(test, not(target_family = "wasm")))]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    /// **Erase is a rewrite** (ADR-0024), and on Windows the log's own handle must allow it: an append-only handle
    /// passes every other store call and fails `set_len` with access denied, which is exactly the erase path.
    #[test]
    fn a_file_store_rewrites_the_log_in_place() {
        let dir = std::env::temp_dir().join(format!("xdict-ledger-store-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("history.log");
        let store = FileStore::open(&path).unwrap();
        store.append(b"one").unwrap();
        store.rewrite(b"two").unwrap();
        assert_eq!(store.load().unwrap(), b"two".to_vec());
        drop(store);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
