//! A Windows file's identity, read from a handle or a path: the volume serial number, the file index, the size, and
//! the last-write and change times in Unix nanoseconds — the tuple `xdict-identity` compares to tell whether a file
//! is the one that was opened (ADR-0002 decision 2, ADR-0007 decision 13).
//!
//! **Why this crate exists.** Rust's stable `std` exposes `last_write_time` but not the file index or the change
//! time (`MetadataExt::file_index` is unstable), and the core's `Location::Path` branch has only `Metadata`. One
//! Win32 call answers all of it, and the workspace forbids `unsafe`; so the call lives here, behind safe functions,
//! as `xdict-mmap` does for `mmap`.
//!
//! **The safety argument.** `GetFileInformationByHandleEx` reads into a local, correctly sized `#[repr(C)]` struct
//! through a handle the caller owns (`File::as_raw_handle`); the structs are plain old data with no pointers, the
//! sizes are `size_of`, and the call is checked for zero before the struct is read. Nothing here maps memory or
//! takes ownership of the handle.
//!
//! **The 128-bit file ID.** `FILE_ID_INFO.FileId` is 128 bits and `FileIdentity.inode` is `u64`. The low 64 bits are
//! used — the value NTFS's own 64-bit index exposes — with the volume serial and the times carrying the rest. A
//! 128-bit ReFS identifier's high half is not compared; that residual is recorded here, not hidden.

#[cfg(not(windows))]
use std::io;

#[cfg(not(windows))]
use xdict_identity::FileIdentity;

#[cfg(windows)]
mod windows {
    use std::ffi::c_void;
    use std::io;
    use std::mem::size_of;
    use std::os::windows::io::AsRawHandle;
    use std::path::Path;

    use xdict_identity::FileIdentity;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct FileId128 {
        id: [u8; 16],
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct FileIdInfo {
        volume: u64,
        file: FileId128,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct FileBasicInfo {
        _creation: i64,
        _access: i64,
        write: i64,
        change: i64,
        _attributes: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct FileStandardInfo {
        _allocation: i64,
        end_of_file: i64,
        _links: u32,
        _delete_pending: u8,
        _directory: u8,
    }

    const FILE_BASIC_INFO: i32 = 0;
    const FILE_STANDARD_INFO: i32 = 1;
    const FILE_ID_INFO: i32 = 18;

    // SAFETY: these declarations match kernel32's signatures; the calls below are the only users, each inside an
    // `unsafe` block with its own argument.
    #[allow(unsafe_code)]
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetFileInformationByHandleEx(handle: *mut c_void, class: i32, info: *mut c_void, size: u32) -> i32;
    }

    /// The identity of an open file.
    pub fn identity(file: &std::fs::File) -> io::Result<FileIdentity> {
        let handle = file.as_raw_handle();

        let mut basic = FileBasicInfo { _creation: 0, _access: 0, write: 0, change: 0, _attributes: 0 };
        // SAFETY: `handle` is the live handle of `file`; `basic` is a correctly sized `#[repr(C)]` buffer the API
        // writes, and nothing else reads it during the call.
        #[allow(unsafe_code)]
        let basic_ok = unsafe {
            GetFileInformationByHandleEx(
                handle,
                FILE_BASIC_INFO,
                (&mut basic as *mut FileBasicInfo).cast::<c_void>(),
                size_of::<FileBasicInfo>() as u32,
            )
        };
        if basic_ok == 0 {
            return Err(io::Error::last_os_error());
        }

        let mut standard =
            FileStandardInfo { _allocation: 0, end_of_file: 0, _links: 0, _delete_pending: 0, _directory: 0 };
        // SAFETY: as above; the class and buffer size are this struct's.
        #[allow(unsafe_code)]
        let standard_ok = unsafe {
            GetFileInformationByHandleEx(
                handle,
                FILE_STANDARD_INFO,
                (&mut standard as *mut FileStandardInfo).cast::<c_void>(),
                size_of::<FileStandardInfo>() as u32,
            )
        };
        if standard_ok == 0 {
            return Err(io::Error::last_os_error());
        }

        let mut id = FileIdInfo { volume: 0, file: FileId128 { id: [0; 16] } };
        // SAFETY: as above; the class and buffer size are this struct's.
        #[allow(unsafe_code)]
        let id_ok = unsafe {
            GetFileInformationByHandleEx(
                handle,
                FILE_ID_INFO,
                (&mut id as *mut FileIdInfo).cast::<c_void>(),
                size_of::<FileIdInfo>() as u32,
            )
        };
        if id_ok == 0 {
            return Err(io::Error::last_os_error());
        }

        let mut low = [0u8; 8];
        low.copy_from_slice(&id.file.id[..8]);
        Ok(FileIdentity {
            device: id.volume,
            inode: u64::from_le_bytes(low),
            size: u64::try_from(standard.end_of_file).unwrap_or(0),
            mtime_ns: to_unix_ns(basic.write),
            ctime_ns: to_unix_ns(basic.change),
        })
    }

    /// The identity of whatever is at `path` now: the file is opened for attributes and asked the same question.
    pub fn identity_of_path(path: &Path) -> io::Result<FileIdentity> {
        let file = std::fs::File::open(path)?;
        identity(&file)
    }

    /// A `FILETIME` is 100-ns intervals since 1601; the core's times are Unix nanoseconds, checked.
    fn to_unix_ns(filetime: i64) -> i64 {
        const EPOCH: i64 = 116_444_736_000_000_000;
        filetime.saturating_sub(EPOCH).saturating_mul(100)
    }
}

#[cfg(windows)]
pub use windows::{identity, identity_of_path};

/// Not Windows: there is no such identity to read.
#[cfg(not(windows))]
pub fn identity(_: &std::fs::File) -> io::Result<FileIdentity> {
    Err(unsupported())
}

/// Not Windows: there is no such identity to read.
#[cfg(not(windows))]
pub fn identity_of_path(_: &std::path::Path) -> io::Result<FileIdentity> {
    Err(unsupported())
}

#[cfg(not(windows))]
fn unsupported() -> io::Error {
    io::Error::new(io::ErrorKind::Unsupported, "a Windows file identity exists on Windows only")
}

#[cfg(all(test, windows))]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("xdict-win-fileid-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// ADR-0002's measurement as a Windows test: equal size, mtime restored, and the change time still tells.
    #[test]
    fn an_in_place_rewrite_with_the_mtime_restored_moves_the_change_time() {
        let dir = scratch("rewrite");
        let path = dir.join("a.bin");
        std::fs::write(&path, b"one").unwrap();
        let first = identity_of_path(&path).unwrap();
        let modified = std::fs::metadata(&path).unwrap().modified().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(&path, b"two").unwrap();
        let file = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
        file.set_modified(modified).unwrap();
        drop(file);
        let second = identity_of_path(&path).unwrap();
        assert_eq!((first.size, first.mtime_ns), (second.size, second.mtime_ns), "size and mtime restored");
        assert_ne!(first.ctime_ns, second.ctime_ns, "the change time moved");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A rename over the name leaves the old file's identity behind: the path now names another file.
    #[test]
    fn a_rename_over_is_another_file() {
        let dir = scratch("rename");
        let path = dir.join("a.bin");
        let other = dir.join("b.bin");
        std::fs::write(&path, b"one").unwrap();
        std::fs::write(&other, b"two").unwrap();
        let first = identity_of_path(&path).unwrap();
        std::fs::rename(&other, &path).unwrap();
        let second = identity_of_path(&path).unwrap();
        assert_ne!((first.device, first.inode), (second.device, second.inode));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
