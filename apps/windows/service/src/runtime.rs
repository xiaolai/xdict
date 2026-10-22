//! Atomic reply groups, bounded service work and a linearized idle transition.
use std::io::{self, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::failure::Failure;
use crate::ops::Events;
use crate::wire::{Answer, CONTRACT};
use serde_json::{Value, json};

pub struct Writer {
    out: Mutex<Box<dyn Write + Send>>,
}

impl Writer {
    pub fn new(out: impl Write + Send + 'static) -> Self {
        Self {
            out: Mutex::new(Box::new(out)),
        }
    }

    pub fn json(&self, value: &Value) {
        if let Ok(bytes) = serde_json::to_vec(value) {
            let mut out = self.out.lock().unwrap_or_else(|p| p.into_inner());
            let _ = frame(out.as_mut(), 1, &bytes);
        }
    }

    pub fn reply(&self, id: u64, outcome: Result<Answer, Failure>) {
        let (record, payload) = match outcome {
            Ok(Answer {
                mut record,
                payload,
            }) => {
                if let Some((bytes, mime)) = &payload {
                    let Some(fields) = record.as_object_mut() else {
                        self.json(&json!({"contract": CONTRACT, "id": id,
                            "error": {"type": "internal", "detail": "bulk answer was not an object"}}));
                        return;
                    };
                    fields.insert(
                        "bulk".into(),
                        json!({"transfer": id, "length": bytes.len(), "mime": mime}),
                    );
                }
                (
                    json!({"contract": CONTRACT, "id": id, "ok": record}),
                    payload,
                )
            }
            Err(error) => (
                json!({"contract": CONTRACT, "id": id, "error": error.to_value()}),
                None,
            ),
        };
        let Ok(bytes) = serde_json::to_vec(&record) else {
            return;
        };
        // One lock for the announcement AND bytes: no event or reply may split this pair.
        let mut out = self.out.lock().unwrap_or_else(|p| p.into_inner());
        if frame(out.as_mut(), 1, &bytes).is_err() {
            return;
        }
        if let Some((bytes, _)) = payload {
            let Ok(length) = u32::try_from(bytes.len() + 8) else {
                return;
            };
            let _ = out.write_all(&length.to_le_bytes());
            let _ = out.write_all(&[2]);
            let _ = out.write_all(&id.to_le_bytes());
            let _ = out.write_all(&bytes);
            let _ = out.flush();
        }
    }
}

fn frame(out: &mut dyn Write, kind: u8, bytes: &[u8]) -> io::Result<()> {
    let length = u32::try_from(bytes.len()).map_err(io::Error::other)?;
    out.write_all(&length.to_le_bytes())?;
    out.write_all(&[kind])?;
    out.write_all(bytes)?;
    out.flush()
}

impl Events for Writer {
    fn progress(&self, id: u64, done: u64, total: u64) {
        self.json(&json!({"contract": CONTRACT, "id": id, "event": "progress", "done": done, "total": total}));
    }
}

pub struct WorkGate(Mutex<[usize; 3]>);
impl WorkGate {
    pub fn new() -> Self {
        Self(Mutex::new([2, 8, 1]))
    }
    pub fn take(self: &Arc<Self>, class: usize) -> Option<Permit> {
        let mut slots = self.0.lock().unwrap_or_else(|p| p.into_inner());
        let slot = slots.get_mut(class)?;
        if *slot == 0 {
            return None;
        }
        *slot -= 1;
        Some(Permit {
            gate: self.clone(),
            class,
        })
    }
}

pub struct Permit {
    gate: Arc<WorkGate>,
    class: usize,
}
impl Drop for Permit {
    fn drop(&mut self) {
        let mut slots = self.gate.0.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(slot) = slots.get_mut(self.class) {
            *slot += 1;
        }
    }
}

pub struct Activity(Mutex<ActivityState>);
struct ActivityState {
    active: usize,
    last: Instant,
    closing: bool,
}
impl Activity {
    pub fn new() -> Self {
        Self(Mutex::new(ActivityState {
            active: 0,
            last: Instant::now(),
            closing: false,
        }))
    }
    pub fn begin(self: &Arc<Self>) -> Option<Active> {
        let mut state = self.0.lock().unwrap_or_else(|p| p.into_inner());
        if state.closing {
            return None;
        }
        state.active += 1;
        Some(Active(self.clone()))
    }
    pub fn idle(&self, duration: Duration) -> bool {
        let mut state = self.0.lock().unwrap_or_else(|p| p.into_inner());
        if state.active == 0 && state.last.elapsed() >= duration {
            state.closing = true;
        }
        state.closing
    }
}

pub struct Active(Arc<Activity>);
impl Drop for Active {
    fn drop(&mut self) {
        let mut state = self.0.0.lock().unwrap_or_else(|p| p.into_inner());
        state.active -= 1;
        state.last = Instant::now();
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::panic, clippy::indexing_slicing)]
    use super::*;
    use std::io::{Cursor, Read};
    use std::thread;

    #[test]
    fn credits_are_service_wide_and_waiting_work_never_spawns() {
        let gate = Arc::new(WorkGate::new());
        let first = gate.take(0).unwrap();
        let _second = gate.take(0).unwrap();
        assert!(gate.take(0).is_none());
        drop(first);
        assert!(gate.take(0).is_some());
        let held: Vec<_> = (0..8).map(|_| gate.take(1).unwrap()).collect();
        assert!(gate.take(1).is_none());
        assert!(gate.take(2).is_some());
        drop(held);
    }

    #[test]
    fn idle_exit_and_request_admission_have_one_winner() {
        let held_activity = Arc::new(Activity::new());
        let held = held_activity.begin().unwrap();
        assert!(!held_activity.idle(Duration::ZERO));
        drop(held);
        for _ in 0..100 {
            let activity = Arc::new(Activity::new());
            let twin = activity.clone();
            let join = thread::spawn(move || twin.begin());
            let exited = activity.idle(Duration::ZERO);
            let accepted = join.join().unwrap();
            if exited {
                assert!(accepted.is_none());
            } else {
                assert!(accepted.is_some());
                assert!(!activity.idle(Duration::ZERO));
            }
            drop(accepted);
            assert!(activity.idle(Duration::ZERO));
            assert!(activity.begin().is_none());
        }
    }

    struct Sink(Arc<Mutex<Vec<u8>>>);
    impl Write for Sink {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            thread::yield_now();
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            thread::yield_now();
            Ok(())
        }
    }

    #[test]
    fn bulk_announcements_and_payloads_cannot_be_interleaved() {
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let writer = Arc::new(Writer::new(Sink(bytes.clone())));
        let threads: Vec<_> = (0..16)
            .map(|worker| {
                let writer = writer.clone();
                thread::spawn(move || {
                    for n in 0..100 {
                        writer.reply(
                            worker * 100 + n,
                            Ok(Answer {
                                record: json!({}),
                                payload: Some((vec![7; 64], "test".into())),
                            }),
                        );
                    }
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        let mut stream = Cursor::new(bytes.lock().unwrap().clone());
        for _ in 0..1600 {
            let mut header = [0; 5];
            stream.read_exact(&mut header).unwrap();
            assert_eq!(header[4], 1);
            let mut record = vec![0; u32::from_le_bytes(header[..4].try_into().unwrap()) as usize];
            stream.read_exact(&mut record).unwrap();
            let record: Value = serde_json::from_slice(&record).unwrap();
            stream.read_exact(&mut header).unwrap();
            assert_eq!(header[4], 2);
            assert_eq!(u32::from_le_bytes(header[..4].try_into().unwrap()), 72);
            let mut id = [0; 8];
            stream.read_exact(&mut id).unwrap();
            assert_eq!(record["id"].as_u64().unwrap(), u64::from_le_bytes(id));
            let mut payload = [0; 64];
            stream.read_exact(&mut payload).unwrap();
            assert_eq!(payload, [7; 64]);
        }
    }
}
