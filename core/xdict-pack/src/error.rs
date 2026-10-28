//! A typed build failure: its kind, where it happened, and what.

use std::fmt;

/// Every way a build can fail, named as the reference implementation names it. The kind is what a shell shows the
/// reader; the message is what a person reads when it is one of ours.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PackErrorKind {
    /// A source, the manifest or a raw file is out of shape.
    Malformed,
    /// A line, field or the pack itself is past a bound.
    Bound,
    /// A file, schema or source version this builder does not read.
    Version,
    /// A record that would carry dictionary content.
    Content,
    /// A source's licence material is missing or unreadable.
    Licence,
    /// A value is still `pending`.
    Pending,
    /// A file does not match its pinned SHA-256 or size.
    Hash,
    /// A file is not there.
    Missing,
    /// The caller asked the build to stop.
    Cancelled,
}

impl PackErrorKind {
    /// The kind as it is written into a message and read by a shell.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Malformed => "malformed",
            Self::Bound => "bound",
            Self::Version => "version",
            Self::Content => "content",
            Self::Licence => "licence",
            Self::Pending => "pending",
            Self::Hash => "hash",
            Self::Missing => "missing",
            Self::Cancelled => "cancelled",
        }
    }
}

impl fmt::Display for PackErrorKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One failure: `kind: [source[:line]: ]message`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackError {
    kind: PackErrorKind,
    source: Option<String>,
    line: Option<u64>,
    message: String,
}

impl PackError {
    /// A failure with no source named.
    pub fn new(kind: PackErrorKind, message: impl Into<String>) -> Self {
        Self { kind, source: None, line: None, message: message.into() }
    }

    /// A failure inside one named source.
    pub fn at_source(kind: PackErrorKind, source: impl Into<String>, message: impl Into<String>) -> Self {
        Self { kind, source: Some(source.into()), line: None, message: message.into() }
    }

    /// A failure on one line of one named source.
    pub fn at(kind: PackErrorKind, source: impl Into<String>, line: u64, message: impl Into<String>) -> Self {
        Self { kind, source: Some(source.into()), line: Some(line), message: message.into() }
    }

    /// Which kind of failure this is.
    pub fn kind(&self) -> PackErrorKind {
        self.kind
    }

    /// The source named, if any.
    pub fn source_id(&self) -> Option<&str> {
        self.source.as_deref()
    }

    /// The line named, if any.
    pub fn line(&self) -> Option<u64> {
        self.line
    }

    /// The message, without the kind or the place.
    pub fn message(&self) -> &str {
        &self.message
    }

    /// This failure, charged to a source it did not name (a record's provider in `PackBuilder::add`).
    pub fn with_source(mut self, source: impl Into<String>) -> Self {
        if self.source.is_none() {
            self.source = Some(source.into());
        }
        self
    }
}

impl fmt::Display for PackError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let where_ = match (&self.source, self.line) {
            (Some(source), Some(line)) => format!("{source}:{line}"),
            (Some(source), None) => source.clone(),
            (None, Some(line)) => format!(":{line}"),
            (None, None) => String::new(),
        };
        if where_.is_empty() {
            write!(f, "{}: {}", self.kind, self.message)
        } else {
            write!(f, "{}: {where_}: {}", self.kind, self.message)
        }
    }
}

impl std::error::Error for PackError {}

/// The `Result` this crate returns.
pub type PackResult<T> = Result<T, PackError>;

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    #[test]
    fn a_message_carries_the_kind_and_the_place() {
        assert_eq!(
            PackError::at(PackErrorKind::Malformed, "cmu", 3, "a word with no phones").to_string(),
            "malformed: cmu:3: a word with no phones"
        );
        assert_eq!(PackError::new(PackErrorKind::Bound, "over").to_string(), "bound: over");
        assert_eq!(
            PackError::at_source(PackErrorKind::Licence, "oewn", "no notice").to_string(),
            "licence: oewn: no notice"
        );
    }

    #[test]
    fn a_plain_failure_takes_the_provider_it_is_charged_to() {
        let error = PackError::new(PackErrorKind::Malformed, "x").with_source("records");
        assert_eq!(error.source_id(), Some("records"));
        let named = PackError::at_source(PackErrorKind::Malformed, "cmu", "x").with_source("records");
        assert_eq!(named.source_id(), Some("cmu"));
    }
}
