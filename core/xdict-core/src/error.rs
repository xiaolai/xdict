//! Errors as codes with typed payloads; the sentence is the shell's, in the reader's language (ADR-0007
//! decision 10). Every variant carries `detail`, for logs only: no shell parses it.

/// Why a call failed.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "type"))]
pub enum CoreError {
    /// The file uses something XDict refuses, named.
    Unsupported {
        feature: Feature,
        detail: String,
    },
    /// The file is damaged, or the shell's request does not fit its call: on the Web, a request that does not parse;
    /// everywhere, a lineage that is not a UUID, or a split into another dictionary's lineage. The call says which.
    Malformed {
        detail: String,
    },
    /// A valid request for more than XDict holds at once: a limit, not damage.
    TooLarge {
        limit: Limit,
        detail: String,
    },
    /// A dictionary, an entry or a key that is not there.
    NotFound {
        what: Missing,
        detail: String,
    },
    Io {
        kind: IoKind,
        detail: String,
    },
    /// A handle from a closed dictionary, another `Core` instance, or another generation.
    StaleHandle {
        detail: String,
    },
    /// An entry reference of one edition given to a dictionary opened at another.
    EditionMismatch {
        detail: String,
    },
    /// The file changed under the core while it was being read (ADR-0007 decision 13).
    SourceChanged {
        detail: String,
    },
    /// The progress callback asked to stop.
    Cancelled {
        detail: String,
    },
    /// The shell and the core speak different protocols (ADR-0007 decision 11).
    Incompatible {
        core: u32,
        client: u32,
        detail: String,
    },
    /// A fault in the core itself, a panic included. Never the dictionary's fault.
    Internal {
        detail: String,
    },
}

/// What [`CoreError::Unsupported`] refuses: the reader's own list (`xdict_mdx::Unsupported`), typed.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "type"))]
pub enum Feature {
    FormatVersion { version: String },
    ResourceLibraryV3,
    RegistrationCode,
    EncryptionFlags { flags: u8 },
    LzoInV3,
    CompressionType { code: u32 },
    BlockEncryption { code: u8 },
    Encoding { name: String },
}

/// Which limit a [`CoreError::TooLarge`] met.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
pub enum Limit {
    /// One of the reader's limits on a file (`xdict_mdx::limits`).
    File,
    /// More results than one page holds ([`crate::MAX_PAGE`]), or more suggestions than one call returns
    /// ([`crate::MAX_SUGGEST`]).
    Page,
    /// A body larger than the view's `max_body_bytes`, or the core's own ceiling.
    Body,
}

/// What a [`CoreError::NotFound`] did not find.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
pub enum Missing {
    /// A file the package names is not at its path.
    File,
    /// An entry reference names no record.
    Entry,
    /// An edition no import has registered.
    Edition,
    /// A lineage no edition was ever minted in, joined to or split to.
    Lineage,
}

/// The kinds of I/O failure a shell may treat differently.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
pub enum IoKind {
    NotFound,
    PermissionDenied,
    /// A source returned fewer bytes than asked.
    ShortRead,
    OutOfMemory,
    Other,
}

impl CoreError {
    pub(crate) fn internal(detail: impl Into<String>) -> Self {
        Self::Internal { detail: detail.into() }
    }

    pub(crate) fn stale(detail: impl Into<String>) -> Self {
        Self::StaleHandle { detail: detail.into() }
    }

    /// An I/O failure; one carrying a shell source's own error is that error.
    pub(crate) fn io(error: &std::io::Error) -> Self {
        if let Some(carried) = error.get_ref().and_then(|inner| inner.downcast_ref::<CoreError>()) {
            return carried.clone();
        }
        Self::Io { kind: io_kind(error), detail: error.to_string() }
    }
}

fn io_kind(error: &std::io::Error) -> IoKind {
    match error.kind() {
        std::io::ErrorKind::NotFound => IoKind::NotFound,
        std::io::ErrorKind::PermissionDenied => IoKind::PermissionDenied,
        std::io::ErrorKind::UnexpectedEof => IoKind::ShortRead,
        std::io::ErrorKind::OutOfMemory => IoKind::OutOfMemory,
        _ => IoKind::Other,
    }
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for CoreError {}

impl From<std::io::Error> for CoreError {
    fn from(error: std::io::Error) -> Self {
        Self::io(&error)
    }
}

impl From<xdict_mdx::Error> for CoreError {
    fn from(error: xdict_mdx::Error) -> Self {
        use xdict_mdx::{Error as E, Unsupported as U};
        let detail = error.to_string();
        match error {
            E::Io(e) => Self::io(&e),
            E::Malformed(_) => Self::Malformed { detail },
            E::TooLarge(_) => Self::TooLarge { limit: Limit::File, detail },
            E::Unsupported(u) => {
                let feature = match u {
                    U::FormatVersion(version) => Feature::FormatVersion { version },
                    U::ResourceLibraryV3 => Feature::ResourceLibraryV3,
                    U::RegistrationCode => Feature::RegistrationCode,
                    U::EncryptionFlags(flags) => Feature::EncryptionFlags { flags },
                    U::Lzo => Feature::LzoInV3,
                    U::CompressionType(code) => Feature::CompressionType { code },
                    U::BlockEncryption(code) => Feature::BlockEncryption { code },
                    U::Encoding(name) => Feature::Encoding { name },
                };
                Self::Unsupported { feature, detail }
            }
        }
    }
}
