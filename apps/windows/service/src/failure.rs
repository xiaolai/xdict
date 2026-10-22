//! What a request fails with: the core's typed error, or one of the wire's own (CONTRACT.md §4).

use serde_json::{Value, json};

use xdict_core::CoreError;

pub enum Failure {
    Core(CoreError),
    /// A request refused before the core saw it.
    Admission(String),
    /// Every slot of its class is taken.
    Busy(String),
}

impl Failure {
    pub fn admission(detail: impl Into<String>) -> Self {
        Self::Admission(detail.into())
    }

    pub fn busy(detail: impl Into<String>) -> Self {
        Self::Busy(detail.into())
    }

    /// The `error` object of a reply. The shell words the sentence; `detail` is for logs only.
    pub fn to_value(&self) -> Value {
        match self {
            Self::Core(error) => serde_json::to_value(error).unwrap_or_else(
                |_| json!({"type": "internal", "detail": "the core's error did not encode"}),
            ),
            Self::Admission(detail) => json!({"type": "admission", "detail": detail}),
            Self::Busy(detail) => json!({"type": "busy", "detail": detail}),
        }
    }
}

impl From<CoreError> for Failure {
    fn from(error: CoreError) -> Self {
        Self::Core(error)
    }
}
