//! The kernel's own transitions, reproduced bit for bit.
//!
//! The fixture is `conformance/review/parity-vectors.json`: 2,000 transitions from a seeded walk in XiaolaiDict's
//! executable specification (`Tools/fsrs/vectors.py`, `fsrs6.py`), all four grades, five retentions, delays from a
//! minute to a year, both sides of the 24-hour boundary. The licence is beside it.
//!
//! Every constant in the scheduler produces a plausible interval when it is wrong; only this test can tell a correct
//! port from a plausible one. A one-ULP mutation must fail it — `a_one_ulp_mutation_is_refused` proves the gate can.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::PathBuf;

use serde::Deserialize;
use xdict_schedule::{Card, DEFAULT_MAXIMUM_DAYS, DEFAULT_WEIGHTS, Grade, Phase, ScheduleError, Scheduler, VERSION};

#[derive(Deserialize)]
struct Vectors {
    version: String,
    transitions: Vec<Transition>,
}

#[derive(Deserialize)]
struct Transition {
    after: State,
    before: State,
    grade: u8,
    now: f64,
    retention: f64,
}

#[derive(Deserialize)]
struct State {
    difficulty: Option<f64>,
    due: Option<f64>,
    #[serde(rename = "lastReview")]
    last_review: Option<f64>,
    phase: String,
    stability: Option<f64>,
}

fn vectors_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../conformance/review/parity-vectors.json")
}

fn card(state: &State) -> Card {
    Card {
        stability: state.stability,
        difficulty: state.difficulty,
        phase: Phase::parse(&state.phase).expect("a phase this version knows"),
        last_review: state.last_review,
        due: state.due,
    }
}

fn load() -> Vectors {
    let text = std::fs::read_to_string(vectors_path()).expect("the parity fixture is beside the crate's tree");
    serde_json::from_str(&text).expect("the parity fixture parses")
}

#[test]
fn the_two_thousand_transitions_are_reproduced_bit_for_bit() {
    let vectors = load();
    assert_eq!(vectors.version, VERSION, "the fixture is from another kernel");
    assert_eq!(vectors.transitions.len(), 2_000, "the gate's count");
    for (index, transition) in vectors.transitions.iter().enumerate() {
        let scheduler = Scheduler::with_configuration(transition.retention, DEFAULT_MAXIMUM_DAYS, DEFAULT_WEIGHTS)
            .expect("the default configuration is valid");
        let after = scheduler
            .review(card(&transition.before), Grade::from_number(transition.grade).expect("a grade"), transition.now)
            .expect("a valid transition");
        let expected = &transition.after;
        assert_eq!(
            after.stability.expect("stability").to_bits(),
            expected.stability.expect("vector stability").to_bits(),
            "transition {index}: stability"
        );
        assert_eq!(
            after.difficulty.expect("difficulty").to_bits(),
            expected.difficulty.expect("vector difficulty").to_bits(),
            "transition {index}: difficulty"
        );
        assert_eq!(after.phase.as_str(), expected.phase, "transition {index}: phase");
        assert_eq!(
            after.last_review.expect("last review").to_bits(),
            expected.last_review.expect("vector last review").to_bits(),
            "transition {index}: lastReview"
        );
        assert_eq!(
            after.due.expect("due").to_bits(),
            expected.due.expect("vector due").to_bits(),
            "transition {index}: due"
        );
    }
}

/// **The gate can fail.** One ULP on `w[3]` moves the first transition's stability, and the same comparison the
/// parity test makes turns red — so a green run means the numbers agree, not that the assertions cannot fail.
#[test]
fn a_one_ulp_mutation_is_refused() {
    let vectors = load();
    let transition = &vectors.transitions[0];
    let mut weights = DEFAULT_WEIGHTS;
    weights[3] = f64::from_bits(weights[3].to_bits() + 1);
    let scheduler = Scheduler::with_configuration(transition.retention, DEFAULT_MAXIMUM_DAYS, weights)
        .expect("the mutated vector is still inside the parameter bounds");
    let after = scheduler
        .review(card(&transition.before), Grade::from_number(transition.grade).expect("a grade"), transition.now)
        .expect("a valid transition");
    assert_ne!(
        after.stability.expect("stability").to_bits(),
        transition.after.stability.expect("vector stability").to_bits(),
        "one ULP must be visible"
    );
}

/// The default configuration is the pinned kernel's.
#[test]
fn the_defaults_are_the_kernels() {
    let scheduler = Scheduler::new();
    assert_eq!(scheduler.weights(), &DEFAULT_WEIGHTS);
    assert_eq!(scheduler.maximum_days(), DEFAULT_MAXIMUM_DAYS);
    assert_eq!(scheduler.retention(), 0.9);
}

/// **Inputs the scheduler cannot represent are refused, not saturated.** A NaN or an instant beyond 2^53 slipped
/// past the rollback check and produced a transition; a finite stability could overflow the interval and be clamped.
#[test]
fn unrepresentable_inputs_are_refused() {
    let scheduler = Scheduler::new();
    let now = 1_790_640_000.0;
    assert_eq!(scheduler.review(Card::new(), Grade::Good, 1e20), Err(ScheduleError::InvalidState));
    let base = scheduler.review(Card::new(), Grade::Good, now).expect("a new card");
    let mut nan_last = base;
    nan_last.last_review = Some(f64::NAN);
    assert_eq!(scheduler.review(nan_last, Grade::Good, now + 86_400.0), Err(ScheduleError::InvalidState));
    let mut nan_due = base;
    nan_due.due = Some(f64::NAN);
    assert_eq!(scheduler.review(nan_due, Grade::Good, now + 86_400.0), Err(ScheduleError::InvalidState));
    let mut far = base;
    far.last_review = Some(1e20);
    assert_eq!(scheduler.review(far, Grade::Good, now + 86_400.0), Err(ScheduleError::InvalidState));
    // Instants are whole seconds; a fraction is refused rather than silently truncated.
    assert_eq!(scheduler.review(Card::new(), Grade::Good, now + 0.5), Err(ScheduleError::InvalidState));
    let mut fractional = base;
    fractional.last_review = Some(now + 0.5);
    assert_eq!(scheduler.review(fractional, Grade::Good, now + 86_400.0), Err(ScheduleError::InvalidState));
    assert_eq!(scheduler.scheduled_days(f64::MAX), Err(ScheduleError::NonFinite));
    assert_eq!(scheduler.interval(f64::MAX, None), Err(ScheduleError::NonFinite));
}

/// **The overflow and cap edges.** A recall whose intermediate overflows must still answer the curve; a due date
/// that would leave the representable range is refused, not rounded back in; a cap above 2^53 is exact.
#[test]
fn overflow_and_cap_edges_are_exact_or_refused() {
    let scheduler = Scheduler::new();
    let value = scheduler.recall(f64::MAX, f64::MAX).expect("the curve's answer");
    assert!((value - 0.9).abs() < 1e-12, "elapsed equal to stability is 0.9, not {value}");
    let capped = Scheduler::with_configuration(0.9, 1, DEFAULT_WEIGHTS).expect("a one-day cap");
    let now = 9_007_199_254_654_593.0;
    assert_eq!(capped.review(Card::new(), Grade::Good, now), Err(ScheduleError::InvalidState));
    let big = Scheduler::with_configuration(0.9, 9_007_199_254_740_995, DEFAULT_WEIGHTS).expect("a large cap");
    assert_eq!(big.scheduled_days(1e16), Ok(9_007_199_254_740_995));
    // A cap whose f64 conversion rounds down must not cap a day early.
    let downward = Scheduler::with_configuration(0.9, 9_007_199_254_740_997, DEFAULT_WEIGHTS).expect("a cap");
    assert_eq!(downward.scheduled_days(9_007_199_254_740_996.0), Ok(9_007_199_254_740_996));
    // A quotient that overflows is evaluated in log space: 1.0 / 1e-310 is a tiny but representable probability.
    let tiny = scheduler.recall(1.0, 1e-310).expect("the curve's answer");
    assert!(tiny > 1e-49 && tiny < 1e-47, "expected ≈1.58e-48, got {tiny}");
    // Overflow in the intermediate product while the true quotient is small: the `+1` is not negligible.
    let mut heavy = DEFAULT_WEIGHTS;
    heavy[20] = 0.1;
    let heavy = Scheduler::with_configuration(0.9, DEFAULT_MAXIMUM_DAYS, heavy).expect("a valid vector");
    let value = heavy.recall(f64::MAX, f64::MAX).expect("the curve's answer");
    assert!((value - 0.9).abs() < 1e-12, "elapsed equal to stability is 0.9, not {value}");
}
