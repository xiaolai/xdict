//! Read-only memory maps of the files XDict alone writes: its per-edition indexes.
//!
//! The one crate of the core allowed `unsafe` (`dev-docs/core-api.md` §6 decision 3). A map's pages are
//! clean, file-backed memory: the system can drop them under pressure and read them again, and on iOS they do
//! not count against an extension's footprint the way heap memory does.
//!
//! **The safety argument.** `memmap2::Mmap::map` is unsafe because Rust's guarantees about the `&[u8]` it
//! gives hold only while nobody changes the file underneath. The files mapped here are written by XDict
//! alone, to a temporary name, then renamed into place, and **never written in place**: a rename leaves the
//! mapped inode as it was, so a later index replaces the name, not the bytes being read. Nothing else is meant
//! to touch the cache directory. If something does (a user, a cleaner truncating the file), the system may
//! signal the process on a read past the new end; that is the residual risk, the one `pread` into the heap
//! would avoid at the cost of the memory. A map of a file under 1 byte is refused, since a zero-length map is
//! an error on some systems.

use std::fs::File;
use std::io;
use std::path::Path;

/// A file mapped read-only, for as long as this value lives.
pub struct Mapped {
    map: memmap2::Mmap,
}

impl Mapped {
    /// Maps a file this process's application wrote by rename and never writes in place.
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = File::open(path)?;
        if file.metadata()?.len() == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "an empty file cannot be mapped"));
        }
        // SAFETY: see the module's safety argument: the file is XDict's own, replaced only by rename, so the
        // mapped bytes do not change while the map lives.
        #[allow(unsafe_code)]
        let map = unsafe { memmap2::Mmap::map(&file)? };
        Ok(Self { map })
    }
}

impl AsRef<[u8]> for Mapped {
    fn as_ref(&self) -> &[u8] {
        &self.map
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn a_map_reads_what_was_written_and_survives_a_rename_over_it() {
        let dir = std::env::temp_dir().join(format!("xdict-mmap-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("index");
        std::fs::write(&path, b"first").unwrap();
        let mapped = Mapped::open(&path).unwrap();
        // The way XDict replaces an index: a new file, renamed over the old name.
        std::fs::write(dir.join("index.tmp"), b"second!").unwrap();
        std::fs::rename(dir.join("index.tmp"), &path).unwrap();
        assert_eq!(mapped.as_ref(), b"first");
        assert_eq!(Mapped::open(&path).unwrap().as_ref(), b"second!");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_empty_file_is_refused() {
        let path = std::env::temp_dir().join(format!("xdict-mmap-empty-{}", std::process::id()));
        std::fs::write(&path, b"").unwrap();
        assert!(Mapped::open(&path).is_err());
        std::fs::remove_file(&path).unwrap();
    }
}
