//! The one API every XDict platform calls (ADR-0003, ADR-0007).
//!
//! Message-shaped: plain records and enums in and out, long-lived things as opaque handles. Identity
//! ([`EntryRef`], editions, lineages) is what a shell stores; a dictionary handle is what it passes while
//! running. Only [`Core::import`] reads a whole file; [`Core::open`] never hashes or indexes. Every call
//! returns a typed [`CoreError`], and a panic inside one comes back as [`CoreError::Internal`].

mod core;
mod error;
mod source;
mod store;
mod types;

pub use crate::core::{
    Core, EDITION_SCHEME, INDEX_FORMAT, MAX_PAGE, MAX_RESOURCE_BYTES, MAX_SUGGEST, NORMALIZATION, PROTOCOL,
};
pub use error::{CoreError, Feature, IoKind, Limit, Missing};
pub use source::{ByteSource, MAX_TRANSFER};
pub use store::IndexStorage;
pub use types::*;
