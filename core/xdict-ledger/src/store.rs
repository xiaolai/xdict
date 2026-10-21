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
            std::fs::create_dir_all(parent).map_err(|error| LedgerError::Storage(error.to_string()))?;
        }
        let lock_path = path.with_extension("lock");
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&lock_path)
            .map_err(|error| LedgerError::Storage(error.to_string()))?;
        lock.try_lock_exclusive().map_err(|_| LedgerError::Busy)?;
        let file = std::fs::OpenOptions::new()
            .read(true)
            .append(true)
            .create(true)
            .open(path)
            .map_err(|error| LedgerError::Storage(error.to_string()))?;
        Ok(FileStore { file: Mutex::new(file), lock, snapshot: path.with_extension("snapshot") })
    }
}

#[cfg(not(target_family = "wasm"))]
impl Store for FileStore {
    fn load(&self) -> Result<Vec<u8>, LedgerError> {
        let mut file = self.file.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        file.seek(SeekFrom::Start(0)).map_err(|error| LedgerError::Storage(error.to_string()))?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).map_err(|error| LedgerError::Storage(error.to_string()))?;
        Ok(bytes)
    }

    fn append(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        let mut file = self.file.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        file.write_all(bytes).map_err(|error| LedgerError::Storage(error.to_string()))
    }

    fn sync(&self) -> Result<(), LedgerError> {
        let file = self.file.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        file.sync_all().map_err(|error| LedgerError::Storage(error.to_string()))
    }

    fn truncate(&self, length: u64) -> Result<(), LedgerError> {
        let file = self.file.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        file.set_len(length).map_err(|error| LedgerError::Storage(error.to_string()))
    }

    fn rewrite(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        let mut file = self.file.lock().map_err(|_| LedgerError::Storage("the log is poisoned".into()))?;
        file.set_len(0).map_err(|error| LedgerError::Storage(error.to_string()))?;
        file.seek(SeekFrom::Start(0)).map_err(|error| LedgerError::Storage(error.to_string()))?;
        file.write_all(bytes).map_err(|error| LedgerError::Storage(error.to_string()))?;
        file.sync_all().map_err(|error| LedgerError::Storage(error.to_string()))
    }

    fn load_snapshot(&self) -> Result<Option<Vec<u8>>, LedgerError> {
        match std::fs::read(&self.snapshot) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(LedgerError::Storage(error.to_string())),
        }
    }

    /// Written beside the log and renamed over the old one: a reader sees the old snapshot or the new, never a torn one.
    fn save_snapshot(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        let temporary = self.snapshot.with_extension("snapshot.tmp");
        {
            let mut file =
                std::fs::File::create(&temporary).map_err(|error| LedgerError::Storage(error.to_string()))?;
            file.write_all(bytes).map_err(|error| LedgerError::Storage(error.to_string()))?;
            file.sync_all().map_err(|error| LedgerError::Storage(error.to_string()))?;
        }
        std::fs::rename(&temporary, &self.snapshot).map_err(|error| LedgerError::Storage(error.to_string()))
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
