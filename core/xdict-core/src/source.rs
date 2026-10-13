//! Where the core's bytes come from: a path, or a source the shell implements (ADR-0007 decision 4).

use std::io;
use std::sync::Arc;

use crate::types::{FileIdentity, Location};
use crate::{CoreError, IoKind};

/// The most one [`ByteSource::read_at`] is asked for: one block of the reader's.
pub const MAX_TRANSFER: u64 = xdict_mdx::limits::BLOCK_BYTES;

/// Random access to a file the shell holds and the core has no path to (Android SAF, iOS security-scoped
/// files, the Web). **It may be called from several threads at once**, and must answer each call on its own.
pub trait ByteSource: Send + Sync {
    /// The file's length in bytes.
    fn size(&self) -> u64;
    /// Exactly `len` bytes from `offset`; fewer is a failure, which the core reports as
    /// [`IoKind::ShortRead`]. `len` is at most [`MAX_TRANSFER`].
    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError>;
    /// The file's identity, where the platform has one; `None` marks the location weak (ADR-0002, as
    /// amended), and it is re-read rather than trusted.
    fn identity(&self) -> Option<FileIdentity>;
}

/// An opened location: the bytes, and what can tell whether they have changed since.
pub(crate) struct Opened {
    pub(crate) source: Box<dyn xdict_mdx::Source>,
    pub(crate) identity: Option<FileIdentity>,
    check: Check,
}

enum Check {
    /// Compare the held descriptor with what is now at the path.
    #[cfg(any(unix, windows))]
    Path {
        path: String,
        file: Arc<std::fs::File>,
    },
    Source(Arc<dyn ByteSource>),
}

impl Opened {
    pub(crate) fn open(location: &Location) -> Result<Self, CoreError> {
        match location {
            #[cfg(any(unix, windows))]
            Location::Path { path } => {
                let file = Arc::new(std::fs::File::open(path).map_err(|e| CoreError::io(&e))?);
                let metadata = file.metadata().map_err(|e| CoreError::io(&e))?;
                let identity = identity_of(&metadata);
                let source = PathSource { file: file.clone(), len: metadata.len() };
                Ok(Self { source: Box::new(source), identity, check: Check::Path { path: path.clone(), file } })
            }
            #[cfg(not(any(unix, windows)))]
            Location::Path { path } => Err(CoreError::Io {
                kind: IoKind::NotFound,
                detail: format!("this platform has no file system to open {path:?} from"),
            }),
            Location::Source { source, .. } => Ok(Self {
                source: Box::new(Adapter(source.clone())),
                identity: source.identity(),
                check: Check::Source(source.clone()),
            }),
        }
    }

    /// Another reader of the same opened file: the same descriptor, or the same source, never the path again.
    pub(crate) fn reader(&self) -> Box<dyn xdict_mdx::Source> {
        match &self.check {
            #[cfg(any(unix, windows))]
            Check::Path { file, .. } => Box::new(PathSource { file: file.clone(), len: self.source.len() }),
            Check::Source(source) => Box::new(Adapter(source.clone())),
        }
    }

    /// `SourceChanged` when the file is no longer the one that was opened (ADR-0007 decision 13): a path whose
    /// file was replaced or rewritten, or a source whose identity moved. A source without an identity cannot
    /// tell, and is trusted.
    pub(crate) fn unchanged(&self) -> Result<(), CoreError> {
        let now = match &self.check {
            #[cfg(any(unix, windows))]
            Check::Path { path, file } => {
                let held = file.metadata().map_err(|e| CoreError::io(&e))?;
                let at_path = std::fs::metadata(path).map_err(|e| CoreError::io(&e))?;
                let (held, at_path) = (identity_of(&held), identity_of(&at_path));
                if held != at_path {
                    return Err(changed(path));
                }
                held
            }
            Check::Source(source) => source.identity(),
        };
        if self.identity.is_some() && now != self.identity {
            return Err(changed("the source"));
        }
        Ok(())
    }
}

fn changed(what: &str) -> CoreError {
    CoreError::SourceChanged { detail: format!("{what} changed after it was opened") }
}

/// The identity of a file: (device, inode, size, mtime, ctime) on Unix. Windows has no stable inode in Rust's
/// standard library, so its files are weak locations until the shell supplies one.
#[cfg(unix)]
pub(crate) fn identity_of(metadata: &std::fs::Metadata) -> Option<FileIdentity> {
    use std::os::unix::fs::MetadataExt;
    let ns = |s: i64, n: i64| s.saturating_mul(1_000_000_000).saturating_add(n);
    Some(FileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
        size: metadata.size(),
        mtime_ns: ns(metadata.mtime(), metadata.mtime_nsec()),
        ctime_ns: ns(metadata.ctime(), metadata.ctime_nsec()),
    })
}

#[cfg(windows)]
pub(crate) fn identity_of(_: &std::fs::Metadata) -> Option<FileIdentity> {
    None
}

#[cfg(any(unix, windows))]
struct PathSource {
    file: Arc<std::fs::File>,
    len: u64,
}

#[cfg(any(unix, windows))]
impl xdict_mdx::Source for PathSource {
    fn len(&self) -> u64 {
        self.len
    }
    #[cfg(unix)]
    fn read_exact_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        std::os::unix::fs::FileExt::read_exact_at(&*self.file, buf, offset)
    }
    #[cfg(windows)]
    fn read_exact_at(&self, mut offset: u64, mut buf: &mut [u8]) -> io::Result<()> {
        while !buf.is_empty() {
            let n = std::os::windows::fs::FileExt::seek_read(&*self.file, buf, offset)?;
            if n == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            offset += n as u64;
            let rest = std::mem::take(&mut buf);
            buf = rest.get_mut(n..).ok_or(io::ErrorKind::UnexpectedEof)?;
        }
        Ok(())
    }
}

/// A shell's source as the reader's.
pub(crate) fn adapt(source: Arc<dyn ByteSource>) -> Box<dyn xdict_mdx::Source> {
    Box::new(Adapter(source))
}

/// A shell's source as the reader's: reads split into transfers of at most [`MAX_TRANSFER`], each checked
/// for length.
struct Adapter(Arc<dyn ByteSource>);

impl xdict_mdx::Source for Adapter {
    fn len(&self) -> u64 {
        self.0.size()
    }
    fn read_exact_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        let mut at = offset;
        for chunk in buf.chunks_mut(MAX_TRANSFER as usize) {
            let want = u32::try_from(chunk.len()).map_err(|_| io::ErrorKind::InvalidInput)?;
            let got = self.0.read_at(at, want).map_err(to_io)?;
            if got.len() != chunk.len() {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    format!("the source returned {} bytes of {want} at {at}", got.len()),
                ));
            }
            chunk.copy_from_slice(&got);
            at += u64::from(want);
        }
        Ok(())
    }
}

fn to_io(error: CoreError) -> io::Error {
    let kind = match &error {
        CoreError::Io { kind: IoKind::NotFound, .. } => io::ErrorKind::NotFound,
        CoreError::Io { kind: IoKind::PermissionDenied, .. } => io::ErrorKind::PermissionDenied,
        CoreError::Io { kind: IoKind::ShortRead, .. } => io::ErrorKind::UnexpectedEof,
        CoreError::Io { kind: IoKind::OutOfMemory, .. } => io::ErrorKind::OutOfMemory,
        _ => io::ErrorKind::Other,
    };
    io::Error::new(kind, error.to_string())
}

/// Reads a whole location, `chunk` bytes at a time, telling `each` about every chunk.
pub(crate) fn read_all(
    source: &dyn xdict_mdx::Source,
    chunk: u64,
    mut each: impl FnMut(&[u8], u64, u64) -> Result<(), CoreError>,
) -> Result<(), CoreError> {
    let total = source.len();
    let mut buf = vec![0u8; usize::try_from(chunk.min(total)).map_err(|_| CoreError::internal("chunk size"))?];
    let mut at = 0u64;
    while at < total {
        let n = usize::try_from((total - at).min(chunk)).map_err(|_| CoreError::internal("chunk size"))?;
        let part = buf.get_mut(..n).ok_or_else(|| CoreError::internal("chunk size"))?;
        source.read_exact_at(at, part).map_err(|e| CoreError::io(&e))?;
        at += n as u64;
        each(part, at, total)?;
    }
    Ok(())
}

/// The bytes an import hashed, and nothing else: reads go through whole chunks of the file, each checked
/// against the xxh3 recorded when the edition was hashed. An index built through it therefore comes from the
/// same bytes as the edition, whatever the file's layout (Codex objection 4), or the import fails with
/// `SourceChanged`.
pub(crate) struct Verified<'a> {
    pub(crate) source: &'a dyn xdict_mdx::Source,
    pub(crate) chunk: u64,
    pub(crate) sums: &'a [u64],
    /// The chunk read last, by number: key blocks are read in order, so this saves most re-reads.
    pub(crate) last: std::sync::Mutex<Option<(u64, Vec<u8>)>>,
}

impl xdict_mdx::Source for Verified<'_> {
    fn len(&self) -> u64 {
        self.source.len()
    }

    fn read_exact_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        let mut at = offset;
        let mut filled = 0usize;
        while filled < buf.len() {
            let number = at / self.chunk;
            let start = number * self.chunk;
            let mut last = self.last.lock().map_err(|_| io::Error::other("a verified read was poisoned"))?;
            if last.as_ref().is_none_or(|(n, _)| *n != number) {
                let len = usize::try_from((self.source.len().saturating_sub(start)).min(self.chunk))
                    .map_err(|_| io::ErrorKind::InvalidInput)?;
                let mut bytes = vec![0u8; len];
                self.source.read_exact_at(start, &mut bytes)?;
                let expected = self.sums.get(number as usize).copied();
                if expected != Some(xxhash_rust::xxh3::xxh3_64(&bytes)) {
                    return Err(io::Error::other(Changed));
                }
                *last = Some((number, bytes));
            }
            let chunk = last.as_ref().map(|(_, b)| b.as_slice()).unwrap_or(&[]);
            let from = usize::try_from(at - start).map_err(|_| io::ErrorKind::InvalidInput)?;
            let take = (chunk.len().saturating_sub(from)).min(buf.len() - filled);
            if take == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            let (Some(dst), Some(src)) = (buf.get_mut(filled..filled + take), chunk.get(from..from + take)) else {
                return Err(io::ErrorKind::UnexpectedEof.into());
            };
            dst.copy_from_slice(src);
            filled += take;
            at += take as u64;
        }
        Ok(())
    }
}

/// What a verified read fails with when the file is not the one hashed: a type, so the failure is recognised
/// by what it is, not by its words.
#[derive(Debug)]
pub(crate) struct Changed;

impl std::fmt::Display for Changed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the file changed while it was being imported")
    }
}

impl std::error::Error for Changed {}
