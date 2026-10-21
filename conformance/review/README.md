# Review conformance

`parity-vectors.json` — **2,000 FSRS-6 transitions** from XiaolaiDict's executable specification
(`Tools/fsrs/vectors.py` over `fsrs6.py`, upstream py-fsrs commit `9446cb0`, MIT licence in `UPSTREAM-LICENSE.txt`);
version `fsrs6-py9446cb0-one10m-no-fuzz-v1`. Every transition carries a retention, a grade, an instant, the state
before and the state after.

`xdict-schedule`'s `tests/parity.rs` reproduces every one of them **bit for bit** (`to_bits` on every float, exact
phase, last-review and due); a one-ULP change in a weight turns it red. Regenerate the fixture only when the kernel's
numbers are meant to change, and expect the gate to go red when they do — that is the gate working.

The MIT notice must travel with the fixture: the formulas and parameters are derived from py-fsrs.

The parity test parses the fixture with serde_json's `float_roundtrip` feature. Without it, serde_json's fast path can
read a double one ULP off and a correct port looks like a scheduler defect (found 2026-10-21, transition 7).
