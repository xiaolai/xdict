//! Read-only memory maps of the files XDict alone writes: its per-edition indexes.
//!
//! The one crate of the core allowed `unsafe` (`dev-docs/core-api.md` §6 decision 3). A map's pages are
//! clean, file-backed memory: the system can drop them under pressure and read them again, and on iOS they do
//! not count against an extension's footprint the way heap memory does.
//!
//! **The safety argument.** `memmap2::Mmap::map` is unsafe because Rust's guarantees about the `&[u8]` it
//! gives hold only while nobody changes the file underneath. So nothing here maps a path it is handed: an
//! [`OwnDirectory`] is both the only writer and the only mapper of its files. It writes each one whole to a
//! temporary name, read-only, and renames it into place, **never writing in place**: a rename leaves a mapped
//! inode as it was, so a later index replaces the name, not the bytes being read. It maps only a plain name
//! inside the directory, never a symbolic link, and on Unix only a regular file that nobody may write, its owner
//! included, which is how it writes them; anything else is refused as if absent, so the caller writes it again.
//! An ordinary write into a mapped index therefore fails with `PermissionDenied`, whoever chose the directory.
//!
//! What code cannot rule out is a process of the same user first making one of these files writable and then
//! writing into it in place, as it could write into XDict's memory: the residual risk, the one `pread` into the
//! heap would avoid at the cost of the memory. Making [`OwnDirectory::new`] `unsafe` would name it but not
//! remove it, and the core, which forbids `unsafe`, could no longer call it.
//!
//! On Windows the mode is not set, but a map holds its file open sharing reading and deletion only, so Windows
//! refuses every open for writing while the map lives, its owner's included, and a rename over the name still
//! replaces it. A file some other process holds open for writing is refused as foreign. A map of a file under
//! 1 byte is refused, since a zero-length map is an error on some systems.

use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};

/// A file mapped read-only, for as long as this value lives.
pub struct Mapped {
    map: memmap2::Mmap,
    /// Held for as long as the map: on Windows, its sharing mode is what keeps writers out.
    _file: File,
}

impl AsRef<[u8]> for Mapped {
    fn as_ref(&self) -> &[u8] {
        &self.map
    }
}

/// A directory whose files XDict alone writes, by [`OwnDirectory::replace`], and maps.
pub struct OwnDirectory {
    dir: PathBuf,
}

impl OwnDirectory {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// Maps the file `name`. `NotFound` when there is none; `UnexpectedEof` when it is empty; `InvalidData` when
    /// it is not a file this directory wrote (a link, another kind of file, one that anybody may write).
    pub fn map(&self, name: &str) -> io::Result<Mapped> {
        let path = self.path(name)?;
        let meta = std::fs::symlink_metadata(&path)?;
        if !meta.file_type().is_file() || writable(&meta) {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "not a file XDict wrote"));
        }
        let file = open_read_only(&path)?;
        // The file opened is the one checked: a rename in between would leave a file of another identity.
        if !same_file(&meta, &file.metadata()?) {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "the file changed as it was opened"));
        }
        if meta.len() == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "an empty file cannot be mapped"));
        }
        // SAFETY: see the module's safety argument: the file is a regular, read-only file in this directory,
        // written by `replace` and replaced only by rename, so the mapped bytes do not change while the map lives.
        #[allow(unsafe_code)]
        let map = unsafe { memmap2::Mmap::map(&file)? };
        Ok(Mapped { map, _file: file })
    }

    /// Writes `bytes` as the file `name`, whole: a temporary file, read-only, renamed over the name, so a map
    /// of the old file keeps its bytes and a later map sees all of the new one. Not synced: what is written here
    /// is derived and checksummed, and one a crash left short is found and written again.
    pub fn replace(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        use std::io::Write;
        let path = self.path(name)?;
        std::fs::create_dir_all(&self.dir)?;
        // A unique temporary name in the same directory, so the rename is atomic and two writers at once do not
        // write into each other's file.
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let temporary = self.dir.join(format!(".{name}.{}.{n}.tmp", std::process::id()));
        let written = (|| {
            let mut options = std::fs::OpenOptions::new();
            options.write(true).create_new(true);
            // Created read-only for everyone: the descriptor opened here can still write it, nothing later can.
            #[cfg(unix)]
            std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o400);
            let mut file = options.open(&temporary)?;
            file.write_all(bytes)?;
            std::fs::rename(&temporary, &path)
        })();
        if written.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        written
    }

    /// The path of `name`, which must be a plain file name: nothing here reaches outside the directory.
    fn path(&self, name: &str) -> io::Result<PathBuf> {
        let mut parts = Path::new(name).components();
        match (parts.next(), parts.next()) {
            (Some(std::path::Component::Normal(_)), None) => Ok(self.dir.join(name)),
            _ => Err(io::Error::new(io::ErrorKind::InvalidInput, format!("{name:?} is not a plain file name"))),
        }
    }
}

#[cfg(unix)]
fn writable(meta: &std::fs::Metadata) -> bool {
    std::os::unix::fs::PermissionsExt::mode(&meta.permissions()) & 0o222 != 0
}

#[cfg(not(unix))]
fn writable(_: &std::fs::Metadata) -> bool {
    false
}

#[cfg(not(windows))]
fn open_read_only(path: &Path) -> io::Result<File> {
    File::open(path)
}

/// Opens `path` to read, sharing it for reading and deletion but not writing: until the handle closes, Windows
/// refuses anyone an open for writing, and a file already open for writing elsewhere is refused here.
#[cfg(windows)]
fn open_read_only(path: &Path) -> io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_SHARE_READ: u32 = 0x1;
    const FILE_SHARE_DELETE: u32 = 0x4;
    const ERROR_SHARING_VIOLATION: i32 = 32;
    std::fs::OpenOptions::new().read(true).share_mode(FILE_SHARE_READ | FILE_SHARE_DELETE).open(path).map_err(|e| {
        if e.raw_os_error() == Some(ERROR_SHARING_VIOLATION) {
            io::Error::new(io::ErrorKind::InvalidData, "another process has the file open for writing")
        } else {
            e
        }
    })
}

#[cfg(unix)]
fn same_file(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    (a.dev(), a.ino()) == (b.dev(), b.ino())
}

#[cfg(not(unix))]
fn same_file(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    a.len() == b.len() && a.modified().ok() == b.modified().ok()
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> OwnDirectory {
        let dir = std::env::temp_dir().join(format!("xdict-mmap-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        OwnDirectory::new(dir)
    }

    #[test]
    fn a_map_reads_what_was_written_and_survives_a_replacement() {
        let own = scratch("replace");
        own.replace("index", b"first").unwrap();
        let mapped = own.map("index").unwrap();
        own.replace("index", b"second!").unwrap();
        assert_eq!(mapped.as_ref(), b"first");
        assert_eq!(own.map("index").unwrap().as_ref(), b"second!");
        std::fs::remove_dir_all(&own.dir).unwrap();
    }

    #[test]
    fn an_absent_or_empty_file_is_refused_by_kind() {
        let own = scratch("empty");
        assert_eq!(own.map("none").err().unwrap().kind(), io::ErrorKind::NotFound);
        own.replace("empty", b"").unwrap();
        assert_eq!(own.map("empty").err().unwrap().kind(), io::ErrorKind::UnexpectedEof);
        std::fs::remove_dir_all(&own.dir).unwrap();
    }

    /// Only a plain name inside the directory is mapped or written: no other path reaches the map.
    #[test]
    fn a_name_cannot_leave_the_directory() {
        let own = scratch("names");
        for name in ["../escape", "a/b", "/etc/hosts", "..", ""] {
            assert_eq!(own.map(name).err().unwrap().kind(), io::ErrorKind::InvalidInput, "{name:?}");
            assert_eq!(own.replace(name, b"x").err().unwrap().kind(), io::ErrorKind::InvalidInput, "{name:?}");
        }
    }

    /// A file this directory did not write is not mapped: a link to another file, or one others may write.
    #[cfg(unix)]
    #[test]
    fn a_file_it_did_not_write_is_refused() {
        let own = scratch("foreign");
        own.replace("index", b"ours").unwrap();
        let outside = own.dir.with_extension("outside");
        std::fs::write(&outside, b"theirs").unwrap();
        std::os::unix::fs::symlink(&outside, own.dir.join("linked")).unwrap();
        assert_eq!(own.map("linked").err().unwrap().kind(), io::ErrorKind::InvalidData);
        std::fs::write(own.dir.join("shared"), b"anyone's").unwrap();
        std::fs::set_permissions(own.dir.join("shared"), std::os::unix::fs::PermissionsExt::from_mode(0o666)).unwrap();
        assert_eq!(own.map("shared").err().unwrap().kind(), io::ErrorKind::InvalidData);
        assert_eq!(own.map("index").unwrap().as_ref(), b"ours");
        std::fs::remove_dir_all(&own.dir).unwrap();
        std::fs::remove_file(&outside).unwrap();
    }

    /// While a map lives, Windows refuses anyone an open for writing, and a rename still replaces the name.
    #[cfg(windows)]
    #[test]
    fn a_mapped_file_cannot_be_opened_for_writing() {
        let own = scratch("sharing");
        own.replace("index", b"ours").unwrap();
        let mapped = own.map("index").unwrap();
        assert!(std::fs::OpenOptions::new().write(true).open(own.dir.join("index")).is_err());
        own.replace("index", b"theirs").unwrap();
        assert_eq!(mapped.as_ref(), b"ours");
        drop(mapped);
        assert_eq!(own.map("index").unwrap().as_ref(), b"theirs");
        std::fs::remove_dir_all(&own.dir).unwrap();
    }

    /// What `replace` writes nobody may write, its owner included, so an ordinary write into a mapped index fails
    /// instead of changing the bytes under the map; a file its owner may write is not one `replace` wrote.
    #[cfg(unix)]
    #[test]
    fn a_file_anyone_may_write_is_refused_and_ours_cannot_be_written() {
        use std::os::unix::fs::PermissionsExt;
        let own = scratch("readonly");
        own.replace("index", b"ours").unwrap();
        let mode = std::fs::metadata(own.dir.join("index")).unwrap().permissions().mode();
        assert_eq!(mode & 0o222, 0, "replace wrote mode {mode:o}");
        let mapped = own.map("index").unwrap();
        let written = std::fs::OpenOptions::new().write(true).open(own.dir.join("index"));
        assert_eq!(written.err().unwrap().kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(mapped.as_ref(), b"ours");
        std::fs::write(own.dir.join("owners"), b"owner-writable").unwrap();
        std::fs::set_permissions(own.dir.join("owners"), PermissionsExt::from_mode(0o600)).unwrap();
        assert_eq!(own.map("owners").err().unwrap().kind(), io::ErrorKind::InvalidData);
        std::fs::remove_dir_all(&own.dir).unwrap();
    }
}
