//! The service's file sources: handles the app duplicated into this process, the identity the core compares, and the
//! app's path observations merged so an older one never replaces a newer (CONTRACT.md §2; the macOS `IdentityRule`).
//!
//! **The safety argument.** The app duplicates a file's HANDLE into this process with `DUPLICATE_SAME_ACCESS` and sends
//! its numeric value once, for one request. Nobody else here owns that value, so `File::from_raw_handle` is its only
//! owner and dropping the source closes it. The one other call, a zero-length `WriteFile`, asks whether the handle was
//! opened for writing: it writes nothing, moves no file pointer, and its refusal is the check.

use std::collections::HashMap;
use std::ffi::c_void;
use std::fs::File;
use std::io;
use std::os::windows::fs::FileExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, RawHandle};
use std::sync::{Arc, Mutex};

use xdict_core::{ByteSource, CoreError, FileIdentity};

use crate::failure::Failure;
use crate::wire::FileSpec;

#[allow(unsafe_code)]
#[link(name = "kernel32")]
unsafe extern "system" {
    fn WriteFile(
        handle: *mut c_void,
        buffer: *const u8,
        bytes: u32,
        written: *mut u32,
        overlapped: *mut c_void,
    ) -> i32;
    fn GetLastError() -> u32;
}

/// The only error that proves a handle was opened without write access.
const ERROR_ACCESS_DENIED: u32 = 5;

/// The app's newest observation of one file's path. `identity` is `None` when nothing is at the path.
#[derive(Debug, Clone, Copy)]
pub struct Observation {
    pub observed_at: u64,
    pub identity: Option<FileIdentity>,
}

/// The app's observations, the newest per file (`TokenLedger` on macOS).
#[derive(Default)]
pub struct Ledger {
    newest: Mutex<HashMap<String, Observation>>,
}

impl Ledger {
    pub fn merge(&self, file: &str, observation: Observation) {
        let mut newest = self
            .newest
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match newest.get(file) {
            Some(held) if held.observed_at >= observation.observed_at => {}
            _ => {
                newest.insert(file.to_string(), observation);
            }
        }
    }

    /// The newest state: `None` when no observation exists, `Some(None)` when the path is gone.
    pub fn state(&self, file: &str) -> Option<Option<FileIdentity>> {
        self.newest
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(file)
            .map(|observation| observation.identity)
    }
}

/// What the service admits a file from: a regular file, opened read-only, with an observation.
pub struct HandleSource {
    file: File,
    id: String,
    name: String,
    at_open: Option<FileIdentity>,
    ledger: Arc<Ledger>,
}

impl HandleSource {
    pub fn take(spec: &FileSpec, ledger: Arc<Ledger>) -> Result<Self, Failure> {
        if spec.handle == 0 || spec.handle > i64::MAX as u64 {
            return Err(Failure::admission(format!("{}: no usable handle", spec.id)));
        }
        // SAFETY: the app duplicated this handle into this process for this request, and nothing else here owns the
        // value; `File` is its only owner from here on.
        #[allow(unsafe_code)]
        let file = unsafe { File::from_raw_handle(spec.handle as RawHandle) };
        let metadata = file
            .metadata()
            .map_err(CoreError::from)
            .map_err(Failure::Core)?;
        if !metadata.is_file() {
            return Err(Failure::admission(format!(
                "{}: not a regular file",
                spec.id
            )));
        }
        if writable(&file) {
            return Err(Failure::admission(format!(
                "{}: opened for writing",
                spec.id
            )));
        }
        let at_open = identity(&file);
        Ok(Self {
            file,
            id: spec.id.clone(),
            name: spec.name.clone(),
            at_open,
            ledger,
        })
    }

    /// The core's name for the file (`Location::Source { name }`): a UUID for an MDX or a volume, a package path for
    /// a sidecar.
    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn held_identity(&self) -> Option<FileIdentity> {
        identity(&self.file)
    }
}

fn identity(file: &File) -> Option<FileIdentity> {
    xdict_win_fileid::identity(file).ok()
}

/// Whether the handle was opened for writing: a zero-length `WriteFile` is refused on a read-only handle and writes
/// nothing on any other.
fn writable(file: &File) -> bool {
    let mut written = 0u32;
    // SAFETY: a live handle, a local buffer, zero bytes, no overlapped I/O.
    #[allow(unsafe_code)]
    let wrote = unsafe {
        WriteFile(
            file.as_raw_handle(),
            &0u8,
            0,
            &mut written,
            std::ptr::null_mut(),
        )
    };
    if wrote != 0 {
        return true;
    }
    // Only ACCESS_DENIED proves the handle is read-only. An overlapped handle answers INVALID_PARAMETER and a stale
    // one INVALID_HANDLE: reading either as "read-only" admitted a handle that may write (CONTRACT.md §2).
    #[allow(unsafe_code)]
    let error = unsafe { GetLastError() };
    error != ERROR_ACCESS_DENIED
}

impl ByteSource for HandleSource {
    fn size(&self) -> u64 {
        self.file
            .metadata()
            .map(|metadata| metadata.len())
            .unwrap_or_else(|_| self.at_open.map_or(0, |at_open| at_open.size))
    }

    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        let mut bytes = vec![0u8; len as usize];
        let mut filled = 0usize;
        while filled < bytes.len() {
            let Some(destination) = bytes.get_mut(filled..) else {
                return Err(CoreError::Internal {
                    detail: "source read exceeded its buffer".into(),
                });
            };
            let position =
                offset
                    .checked_add(filled as u64)
                    .ok_or_else(|| CoreError::Malformed {
                        detail: "source offset overflow".into(),
                    })?;
            match self.file.seek_read(destination, position) {
                Ok(0) => break,
                Ok(read) => filled += read,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error.into()),
            }
        }
        bytes.truncate(filled);
        Ok(bytes)
    }

    fn identity(&self) -> Option<FileIdentity> {
        identity_rule(
            self.at_open,
            identity(&self.file),
            self.ledger.state(&self.id),
        )
    }
}

/// The identity the core sees: the held handle's when it moved, else the newest path observation when it differs,
/// else the held one (`IdentityRule`).
pub fn identity_rule(
    at_open: Option<FileIdentity>,
    held: Option<FileIdentity>,
    token: Option<Option<FileIdentity>>,
) -> Option<FileIdentity> {
    if held != at_open {
        return held;
    }
    match token {
        None => held,
        Some(None) => None,
        Some(Some(at_path)) => {
            if Some(at_path) != at_open {
                Some(at_path)
            } else {
                held
            }
        }
    }
}

/// Admits every file a request names: an observation must be present, and the handle must be the file the app
/// observed (or the one the service last saw).
pub fn admit(
    specs: &[FileSpec],
    ledger: &Arc<Ledger>,
) -> Result<HashMap<String, HandleSource>, Failure> {
    let mut sources = HashMap::new();
    // One HANDLE value, one owner: two specs naming it would become two `File`s over one handle and close it twice.
    let mut handles = std::collections::HashSet::new();
    for spec in specs {
        if !handles.insert(spec.handle) {
            return Err(Failure::Core(xdict_core::CoreError::Malformed {
                detail: format!("the handle {} is named by two files", spec.handle),
            }));
        }
        let previous = ledger.state(&spec.id).flatten();
        ledger.merge(
            &spec.id,
            Observation {
                observed_at: spec.observed_at,
                identity: spec.identity,
            },
        );
        let source = HandleSource::take(spec, ledger.clone())?;
        let held = source.held_identity();
        match spec.identity {
            Some(observed) if held != Some(observed) && !same_object(held, previous) => {
                return Err(Failure::admission(format!(
                    "{}: the handle is not the file the path names",
                    spec.id
                )));
            }
            None if previous.is_some() && !same_object(held, previous) => {
                return Err(Failure::admission(format!(
                    "{}: the path is gone and the handle is not the file last seen",
                    spec.id
                )));
            }
            _ => {}
        }
        if sources.insert(spec.id.clone(), source).is_some() {
            return Err(Failure::admission(format!("{}: sent twice", spec.id)));
        }
    }
    Ok(sources)
}

// The held object's times may have moved since the last observation. Admit that same file object so the core's
// IdentityRule returns SourceChanged; a replacement object still needs a matching current path observation.
fn same_object(left: Option<FileIdentity>, right: Option<FileIdentity>) -> bool {
    matches!((left, right), (Some(left), Some(right)) if left.device == right.device && left.inode == right.inode)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(inode: u64, time: i64) -> FileIdentity {
        FileIdentity {
            device: 1,
            inode,
            size: 5,
            mtime_ns: time,
            ctime_ns: time,
        }
    }

    #[test]
    fn path_observation_is_used_when_the_held_file_did_not_move() {
        let held = Some(identity(1, 1));
        let replacement = Some(identity(2, 2));
        assert_eq!(identity_rule(held, held, Some(replacement)), replacement);
        assert_eq!(identity_rule(held, held, Some(None)), None);
        let moved = Some(identity(1, 3));
        assert_eq!(identity_rule(held, moved, Some(replacement)), moved);
        assert!(same_object(held, moved));
        assert!(!same_object(held, replacement));
    }

    #[test]
    fn an_old_observation_cannot_replace_a_new_one() {
        let ledger = Ledger::default();
        ledger.merge(
            "a",
            Observation {
                observed_at: 2,
                identity: Some(identity(1, 2)),
            },
        );
        ledger.merge(
            "a",
            Observation {
                observed_at: 1,
                identity: Some(identity(2, 1)),
            },
        );
        assert_eq!(ledger.state("a"), Some(Some(identity(1, 2))));
    }
}
