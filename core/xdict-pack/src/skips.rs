//! How many source rows a parse left out, by reason, and the metadata samples the report keeps of the first few.

use std::collections::BTreeMap;

use crate::json::Value;
use crate::limits::MAX_SKIPPED_SAMPLES;

/// The rows a parse skipped, counted by reason, with the first [`MAX_SKIPPED_SAMPLES`] of each kept as metadata.
#[derive(Debug, Clone, Default)]
pub struct Skips {
    counts: BTreeMap<String, u64>,
    samples: BTreeMap<String, Vec<Value>>,
}

impl Skips {
    /// A fresh tally.
    pub fn new() -> Self {
        Self::default()
    }

    /// Counts one skipped row under `reason` and, while that reason holds fewer than the bound, keeps `sample`.
    pub fn record(&mut self, reason: &str, sample: Option<Value>) {
        *self.counts.entry(reason.to_string()).or_insert(0) += 1;
        let Some(sample) = sample else { return };
        let bucket = self.samples.entry(reason.to_string()).or_default();
        if bucket.len() < MAX_SKIPPED_SAMPLES {
            bucket.push(sample);
        }
    }

    /// The reasons and their counts.
    pub fn counts(&self) -> &BTreeMap<String, u64> {
        &self.counts
    }

    /// The reasons' samples.
    pub fn samples(&self) -> &BTreeMap<String, Vec<Value>> {
        &self.samples
    }

    /// Whether nothing was skipped.
    pub fn is_empty(&self) -> bool {
        self.counts.is_empty()
    }
}

/// A skipped-row sample: its metadata, with empty values dropped, as the reference implementation keeps one.
pub fn sample(pairs: Vec<(&str, Value)>) -> Value {
    Value::obj(pairs.into_iter().filter(|(_, value)| !matches!(value, Value::Str(text) if text.is_empty())).collect())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    #[test]
    fn a_reason_counts_every_row_and_keeps_fifty() {
        let mut skips = Skips::new();
        for line in 1..=60 {
            skips.record("a reason", Some(sample(vec![("line", Value::Int(line))])));
        }
        assert_eq!(skips.counts().get("a reason"), Some(&60));
        assert_eq!(skips.samples().get("a reason").map(Vec::len), Some(MAX_SKIPPED_SAMPLES));
    }

    #[test]
    fn an_empty_value_is_dropped_from_a_sample() {
        let kept = sample(vec![("line", Value::Int(3)), ("word", Value::str("")), ("kind", Value::str("x"))]);
        assert_eq!(kept, Value::obj(vec![("line", Value::Int(3)), ("kind", Value::str("x"))]));
    }
}
