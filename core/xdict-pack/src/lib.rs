//! Builds the word pack from the pinned upstream sources, on the reader's Mac.
//!
//! XDict generates nothing and hosts nothing (the owner's decision, 2026-10-28): the reader downloads the pinned
//! sources and this crate builds the pack locally. No Python, no toolchain, and no derived artifact of ours anywhere
//! on the network.
//!
//! The pack is `xdict-word-pack` v2, the JSONL [`xdict_core::words`]'s loader reads: a header naming every source
//! (URL, pinned version, SHA-256 of the raw download, licence, short attribution, coverage), then one typed record
//! per line. Records hold linguistic metadata only; a definition, gloss, example or prose etymology is never read
//! into one, and the writer refuses any record carrying such a key. The complete licence notices go to a sidecar
//! that travels with the pack.
//!
//! The reference implementation is `core/xdict-pack/reference/word_lexicon.py`, and `WORD_LEXICON.md` is the written
//! spec. This crate is held to it byte for byte: a build from the pinned sources produces a pack whose SHA-256 is
//! `f33954be3b147fc7da87dba9b5fd6b11314aaa8e268b21137da407b0c691b7a8`.
//!
//! ```no_run
//! use xdict_pack::{build, BuildOptions, Control};
//!
//! let options = BuildOptions::new("/raw", "/pack/xdict-words-en.jsonl", "/raw/word_lexicon_sources.json");
//! let report = build(&options, &mut |_event| Control::Continue)?;
//! println!("{}", report.pack_sha256);
//! # Ok::<(), xdict_pack::PackError>(())
//! ```

pub mod build;
pub mod builder;
pub mod cmudict;
pub mod error;
pub mod etymology;
pub mod json;
pub mod limits;
pub mod manifest;
pub mod morphynet;
pub mod notices;
pub mod oewn;
pub mod record;
pub mod skips;
pub mod sources;
pub mod text;
pub mod zip;

pub use build::{BuildOptions, Control, Event, Report, atomic_write, build, refuse_inside_repository, write_pack};
pub use error::{PackError, PackErrorKind, PackResult};
pub use record::{RawRecord, Record};
pub use sources::{Csv, Line, Lines};

/// What a parser hands each record to: a sink that may refuse it, and so stop the parse.
pub type Emit<'a> = &'a mut dyn FnMut(RawRecord) -> PackResult<()>;
