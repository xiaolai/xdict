//! **FSRS-6, ported from XiaolaiDict's executable specification** (`Tools/fsrs/fsrs6.py`, itself a port of the
//! MIT-licensed py-fsrs commit `9446cb0`): one 10-minute learning/relearning step, no fuzz, whole elapsed days,
//! ties-to-even interval rounding.
//!
//! **Pure.** No storage, no eligibility, no idempotency — those are the caller's, and they are where the product
//! decisions live. This answers one question: given a card, a grade and an instant, what is the card now.
//!
//! Every constant here produces a plausible interval when it is wrong, and a scheduler that is subtly wrong looks
//! exactly like a correct one until a reader has lost a year of reviews. The gate is `tests/parity.rs`: 2,000
//! transitions from `conformance/review/parity-vectors.json`, compared bit for bit.
//!
//! Three things the specification calls out that a careless port loses, each kept deliberately below:
//!
//! - the mean-reversion anchor `d₀(4)` is **raw and unclamped**; clamping it first is a different model;
//! - stability is computed from the **old** difficulty, and difficulty updated after;
//! - the post-lapse **ceiling** on stability, which the overview omits.

use thiserror::Error;

/// The default configuration's identity: the pinned kernel with [`DEFAULT_WEIGHTS`] and
/// [`DEFAULT_MAXIMUM_DAYS`]. A change to rounding, time semantics, steps or fuzz is a change to the scheduling
/// contract and must change this string, or a replay will silently use today's rules on yesterday's history.
pub const VERSION: &str = "fsrs6-py9446cb0-one10m-no-fuzz-v1";

/// The population-derived starting model — **not** a calibrated profile of this reader.
pub const DEFAULT_WEIGHTS: [f64; 21] = [
    0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629,
    1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
];

const LOWER: [f64; 21] = [
    0.001, 0.001, 0.001, 0.001, 1.0, 0.001, 0.001, 0.001, 0.0, 0.0, 0.001, 0.001, 0.001, 0.001, 0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.1,
];

const UPPER: [f64; 21] = [
    100.0, 100.0, 100.0, 100.0, 10.0, 4.0, 4.0, 0.75, 4.5, 0.8, 3.5, 5.0, 0.25, 0.9, 4.0, 1.0, 6.0, 2.0, 2.0, 0.8, 0.8,
];

/// The interval cap the default configuration schedules with, in days.
pub const DEFAULT_MAXIMUM_DAYS: i64 = 36_500;

const SECONDS_PER_DAY: f64 = 86_400.0;

/// The largest whole-second instant a `f64` counts exactly (2^53).
const MAX_TIMESTAMP_SECONDS: f64 = 9_007_199_254_740_992.0;

/// The card's stage. A new card graduates through `Learning`; a lapse sends a `Review` card to `Relearning`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    New,
    Learning,
    Review,
    Relearning,
}

impl Phase {
    /// The wire spelling, the same one the vectors use.
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::New => "new",
            Phase::Learning => "learning",
            Phase::Review => "review",
            Phase::Relearning => "relearning",
        }
    }

    /// The vector spelling, or `None` for a name this version does not know.
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "new" => Some(Phase::New),
            "learning" => Some(Phase::Learning),
            "review" => Some(Phase::Review),
            "relearning" => Some(Phase::Relearning),
            _ => None,
        }
    }
}

/// A card as the scheduler sees it: its memory state and when it is due, in whole epoch seconds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Card {
    pub stability: Option<f64>,
    pub difficulty: Option<f64>,
    pub phase: Phase,
    pub last_review: Option<f64>,
    pub due: Option<f64>,
}

impl Card {
    /// A card that has never been reviewed.
    pub fn new() -> Self {
        Card { stability: None, difficulty: None, phase: Phase::New, last_review: None, due: None }
    }
}

impl Default for Card {
    fn default() -> Self {
        Card::new()
    }
}

/// The reader's answer: again, hard, good or easy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Grade {
    Again = 1,
    Hard = 2,
    Good = 3,
    Easy = 4,
}

impl Grade {
    pub fn from_number(number: u8) -> Result<Self, ScheduleError> {
        match number {
            1 => Ok(Grade::Again),
            2 => Ok(Grade::Hard),
            3 => Ok(Grade::Good),
            4 => Ok(Grade::Easy),
            _ => Err(ScheduleError::InvalidGrade),
        }
    }

    pub fn number(self) -> u8 {
        self as u8
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ScheduleError {
    #[error("grade must be 1, 2, 3 or 4")]
    InvalidGrade,
    #[error("retention must be strictly between zero and one")]
    InvalidRetention,
    #[error("the maximum interval must be a positive whole number of days")]
    InvalidMaximumDays,
    #[error("invalid FSRS-6 parameter vector")]
    InvalidWeights,
    #[error("a new card must have no invented memory state")]
    NewCardHasState,
    #[error("invalid memory state")]
    InvalidState,
    #[error("clock rollback: the review precedes the previous review")]
    ClockRollback,
    #[error("nonfinite calculated state")]
    NonFinite,
}

/// **The scheduler** — the pinned kernel's arithmetic and nothing else.
#[derive(Clone, Debug)]
pub struct Scheduler {
    weights: [f64; 21],
    retention: f64,
    maximum_days: i64,
    decay: f64,
    factor: f64,
}

impl Scheduler {
    /// The default configuration: the pinned kernel, retention 0.9 and the default cap.
    pub fn new() -> Self {
        // The default weights are inside LOWER..UPPER by construction; `expect` is forbidden in this workspace,
        // and `configured` is the one place the derived fields are computed.
        Self::configured(DEFAULT_WEIGHTS, 0.9, DEFAULT_MAXIMUM_DAYS)
    }

    /// A configuration, validated exactly as the specification validates it.
    pub fn with_configuration(retention: f64, maximum_days: i64, weights: [f64; 21]) -> Result<Self, ScheduleError> {
        if !retention.is_finite() || retention <= 0.0 || retention >= 1.0 {
            return Err(ScheduleError::InvalidRetention);
        }
        if maximum_days < 1 {
            return Err(ScheduleError::InvalidMaximumDays);
        }
        if weights
            .iter()
            .zip(LOWER.iter().zip(UPPER.iter()))
            .any(|(value, (low, high))| !value.is_finite() || *value < *low || *value > *high)
        {
            return Err(ScheduleError::InvalidWeights);
        }
        Ok(Self::configured(weights, retention, maximum_days))
    }

    /// The one constructor of an already-validated configuration: the derived fields cannot drift between `new` and
    /// `with_configuration`.
    fn configured(weights: [f64; 21], retention: f64, maximum_days: i64) -> Self {
        let decay = -weights.get(20).copied().unwrap_or(f64::NAN);
        let factor = 0.9_f64.powf(1.0 / decay) - 1.0;
        Scheduler { weights, retention, maximum_days, decay, factor }
    }

    pub fn retention(&self) -> f64 {
        self.retention
    }

    pub fn maximum_days(&self) -> i64 {
        self.maximum_days
    }

    pub fn weights(&self) -> &[f64; 21] {
        &self.weights
    }

    /// One weight by its index. A fixed array's literal index cannot be out of bounds; `get` keeps the workspace's
    /// indexing lint, and an impossible index would surface as a non-finite result the checks refuse.
    fn w(&self, index: usize) -> f64 {
        self.weights.get(index).copied().unwrap_or(f64::NAN)
    }

    /// The continuous forgetting curve. Pass whole elapsed days for scheduler parity.
    pub fn recall(&self, elapsed_days: f64, stability: f64) -> Result<f64, ScheduleError> {
        if !stability.is_finite() || stability <= 0.0 || !elapsed_days.is_finite() || elapsed_days < 0.0 {
            return Err(ScheduleError::InvalidState);
        }
        // The kernel's grouping is `(factor * elapsed) / stability`. For two large accepted values that product
        // overflows to infinity and the curve answers 0.0 although elapsed equals stability (0.9 by construction);
        // the fallback keeps the grouping for every ordinary input, so parity is untouched.
        // The kernel's grouping is `1 + (factor * elapsed) / stability`. That quotient can overflow while the true
        // x is small (factor * MAX overflows before MAX / MAX is taken), so the fallback computes `ln(1 + x)` from
        // smaller parts: the ratio first, then the product, and only a genuine huge x drops the `+1`
        // (`ln(1 + x) ≈ ln(x) = ln(factor) + ln(elapsed) - ln(stability)`).
        let quotient = self.factor * elapsed_days / stability;
        let value = if quotient.is_finite() {
            (1.0 + quotient).powf(self.decay)
        } else {
            let ratio = elapsed_days / stability;
            let log_term = if ratio.is_finite() {
                let product = self.factor * ratio;
                if product.is_finite() { product.ln_1p() } else { self.factor.ln() + ratio.ln() }
            } else {
                self.factor.ln() + elapsed_days.ln() - stability.ln()
            };
            (self.decay * log_term).exp()
        };
        if !value.is_finite() {
            return Err(ScheduleError::NonFinite);
        }
        Ok(value)
    }

    /// The interval at which the curve is expected to reach `retention` (the scheduler's own by default).
    pub fn interval(&self, stability: f64, retention: Option<f64>) -> Result<f64, ScheduleError> {
        if !stability.is_finite() || stability <= 0.0 {
            return Err(ScheduleError::InvalidState);
        }
        let target = retention.unwrap_or(self.retention);
        if !target.is_finite() || target <= 0.0 || target >= 1.0 {
            return Err(ScheduleError::InvalidRetention);
        }
        let value = stability / self.factor * (target.powf(1.0 / self.decay) - 1.0);
        // A finite stability can still overflow the intermediate; that is a refused input, never a silent infinity
        // that `scheduled_days` would clamp to the cap.
        if !value.is_finite() {
            return Err(ScheduleError::NonFinite);
        }
        Ok(value)
    }

    /// Whole days until the next review: at least one, at most the cap, ties to even as the kernel rounds.
    pub fn scheduled_days(&self, stability: f64) -> Result<i64, ScheduleError> {
        let interval = self.interval(stability, None)?;
        let rounded = interval.round_ties_even();
        // The cap is an integer, and so is the comparison: `maximum_days as f64` can round up (returning past the
        // maximum) or down (capping a day early), and both are wrong above 2^53. A rounded interval beyond `i64`
        // cannot be a day count at all, so the cap answers for it.
        if rounded >= i64::MAX as f64 {
            return Ok(self.maximum_days);
        }
        let days = rounded as i64;
        if days >= self.maximum_days {
            return Ok(self.maximum_days);
        }
        Ok(days.max(1))
    }

    /// The mean-reversion anchor. **Raw and unclamped** — clamping it first is a different model.
    fn initial_difficulty(&self, grade: Grade) -> f64 {
        self.w(4) - (self.w(5) * (grade.number() as f64 - 1.0)).exp() + 1.0
    }

    /// **A whole epoch-second instant the scheduler can represent.** Beyond 2^53 a double no longer counts seconds,
    /// so elapsed time and due dates stop meaning what the caller thinks; such an instant is refused, not saturated.
    /// A fractional instant is refused too: the arithmetic below is whole-seconds exact, and the ledger stores whole
    /// seconds.
    fn representable(instant: f64) -> bool {
        instant.is_finite() && instant.abs() <= MAX_TIMESTAMP_SECONDS && instant.fract() == 0.0
    }

    /// **Whole elapsed days, exact.** Two accepted instants can differ by more than 2^53 seconds, where subtracting
    /// them as doubles rounds to a different day; the casts are exact for whole seconds within the bound, and the
    /// subtraction is done in integers.
    fn elapsed_days(now: f64, previous: f64) -> Result<i64, ScheduleError> {
        let now_seconds = now as i64;
        let previous_seconds = previous as i64;
        let seconds = now_seconds.checked_sub(previous_seconds).ok_or(ScheduleError::InvalidState)?;
        Ok(seconds.div_euclid(SECONDS_PER_DAY as i64))
    }

    /// The memory state after a grade on an existing card, in the kernel's exact arithmetic order.
    fn memory_after(
        &self,
        stability: f64,
        difficulty: f64,
        grade: Grade,
        days: i64,
    ) -> Result<(f64, f64), ScheduleError> {
        let grade_number = grade.number() as f64;
        let stability = if days == 0 {
            let gain = (self.w(17) * (grade_number - 3.0 + self.w(18))).exp() * stability.powf(-self.w(19));
            stability * if grade.number() >= 2 { gain.max(1.0) } else { gain }
        } else {
            let r = self.recall(days as f64, stability)?;
            if grade == Grade::Again {
                let after_lapse = self.w(11)
                    * difficulty.powf(-self.w(12))
                    * ((stability + 1.0).powf(self.w(13)) - 1.0)
                    * (self.w(14) * (1.0 - r)).exp();
                let ceiling = stability / (self.w(17) * self.w(18)).exp();
                after_lapse.min(ceiling)
            } else {
                let multiplier = match grade {
                    Grade::Hard => self.w(15),
                    Grade::Easy => self.w(16),
                    _ => 1.0,
                };
                stability
                    * (1.0
                        + self.w(8).exp()
                            * (11.0 - difficulty)
                            * stability.powf(-self.w(9))
                            * ((self.w(10) * (1.0 - r)).exp() - 1.0)
                            * multiplier)
            }
        };
        let stability = stability.max(0.001);
        let damped = difficulty - self.w(6) * (grade_number - 3.0) * (10.0 - difficulty) / 9.0;
        let difficulty =
            (self.w(7) * self.initial_difficulty(Grade::Easy) + (1.0 - self.w(7)) * damped).clamp(1.0, 10.0);
        Ok((stability, difficulty))
    }

    /// **An existing card's state, validated, with its exact elapsed days.** The rules are one place so they can be
    /// read together; `review` keeps the transition itself.
    fn existing_state(card: Card, now: f64) -> Result<(f64, f64, i64), ScheduleError> {
        let Some(stability) = card.stability else { return Err(ScheduleError::InvalidState) };
        let Some(difficulty) = card.difficulty else { return Err(ScheduleError::InvalidState) };
        let Some(previous_time) = card.last_review else { return Err(ScheduleError::InvalidState) };
        let Some(due) = card.due else { return Err(ScheduleError::InvalidState) };
        if !Scheduler::representable(previous_time)
            || !Scheduler::representable(due)
            || !stability.is_finite()
            || stability < 0.001
            || !difficulty.is_finite()
            || !(1.0..=10.0).contains(&difficulty)
        {
            return Err(ScheduleError::InvalidState);
        }
        if now < previous_time {
            return Err(ScheduleError::ClockRollback);
        }
        let days = Scheduler::elapsed_days(now, previous_time)?;
        Ok((stability, difficulty, days))
    }

    /// Where the card is headed, and how far away: the kernel's graduation and lapse rules.
    fn phase_and_delay(&self, phase: Phase, grade: Grade, stability: f64) -> Result<(Phase, f64), ScheduleError> {
        if matches!(phase, Phase::Learning | Phase::Relearning) {
            match grade {
                Grade::Again => Ok((phase, 10.0 * 60.0)),
                Grade::Hard => Ok((phase, 15.0 * 60.0)),
                Grade::Good | Grade::Easy => {
                    Ok((Phase::Review, self.scheduled_days(stability)? as f64 * SECONDS_PER_DAY))
                }
            }
        } else if grade == Grade::Again {
            Ok((Phase::Relearning, 10.0 * 60.0))
        } else {
            Ok((phase, self.scheduled_days(stability)? as f64 * SECONDS_PER_DAY))
        }
    }

    /// One grade transition. Eligibility, idempotency and the commit belong to the caller.
    pub fn review(&self, card: Card, grade: Grade, now: f64) -> Result<Card, ScheduleError> {
        if !Self::representable(now) {
            return Err(ScheduleError::InvalidState);
        }
        let (phase, stability, difficulty) = match card.phase {
            Phase::New => {
                if card.stability.is_some()
                    || card.difficulty.is_some()
                    || card.last_review.is_some()
                    || card.due.is_some()
                {
                    return Err(ScheduleError::NewCardHasState);
                }
                let stability = self.w(grade.number() as usize - 1).max(0.001);
                let difficulty = self.initial_difficulty(grade).clamp(1.0, 10.0);
                (Phase::Learning, stability, difficulty)
            }
            Phase::Learning | Phase::Review | Phase::Relearning => {
                let (stability, difficulty, days) = Self::existing_state(card, now)?;
                let (stability, difficulty) = self.memory_after(stability, difficulty, grade, days)?;
                (card.phase, stability, difficulty)
            }
        };
        if !stability.is_finite() || !difficulty.is_finite() {
            return Err(ScheduleError::NonFinite);
        }
        let (phase, delay) = self.phase_and_delay(phase, grade, stability)?;
        // The due time is summed in integers: `now + delay` as doubles can round an out-of-range due back into the
        // accepted range, one second early.
        let now_seconds = now as i64;
        let due_seconds = now_seconds.checked_add(delay as i64).ok_or(ScheduleError::InvalidState)?;
        if due_seconds <= now_seconds || due_seconds.unsigned_abs() > MAX_TIMESTAMP_SECONDS as u64 {
            return Err(ScheduleError::InvalidState);
        }
        let due = due_seconds as f64;
        Ok(Card {
            stability: Some(stability),
            difficulty: Some(difficulty),
            phase,
            last_review: Some(now),
            due: Some(due),
        })
    }
}

impl Default for Scheduler {
    fn default() -> Self {
        Scheduler::new()
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]
mod tests {
    use super::*;

    /// The audit's exact counterexample: two accepted instants whose difference exceeds 2^53 seconds. Subtracting
    /// them as doubles rounds to 9,007,199,254,800,000 and one day too many; integers give the exact day.
    #[test]
    fn elapsed_days_is_exact_beyond_the_float_difference() {
        assert_eq!(
            Scheduler::elapsed_days(59_007.0, -9_007_199_254_740_992.0),
            Ok(104_249_991_374),
            "the exact difference is 9,007,199,254,799,999 seconds"
        );
        assert_eq!(Scheduler::elapsed_days(59_007.0, 59_007.0), Ok(0));
        assert_eq!(Scheduler::elapsed_days(59_007.0, 0.0), Ok(0));
    }
}
