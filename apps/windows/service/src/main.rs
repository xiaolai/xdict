//! Capability-free dictionary service. The parent creates private pipes; there is no listener or path admission.
mod failure;
mod handles;
mod ops;
mod runtime;
mod wire;

use crate::failure::Failure;
use crate::ops::{Service, is_bulk};
use crate::runtime::{Active, Activity, WorkGate, Writer};
use crate::wire::{CONTRACT, Request};
use serde_json::{Value, json};
use std::io::{self, Read};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

const JSON_MAX: usize = 1 << 20;

fn main() {
    let arguments = Arguments::parse();
    for directory in [arguments.data.as_deref(), arguments.cache.as_deref()]
        .into_iter()
        .flatten()
    {
        if let Err(error) = std::fs::create_dir_all(directory) {
            eprintln!("the service cannot create {directory}: {error}");
            std::process::exit(2);
        }
    }
    let core = match ops::core_from(arguments.data, arguments.cache) {
        Ok(core) => core,
        Err(error) => {
            eprintln!("the core did not start: {error:?}");
            std::process::exit(2);
        }
    };
    let writer = Arc::new(Writer::new(io::stdout()));
    let service = Arc::new(Service::new(core));
    let gates = Arc::new(WorkGate::new());
    let activity = Arc::new(Activity::new());
    {
        let activity = activity.clone();
        thread::spawn(move || {
            loop {
                thread::sleep(Duration::from_millis(100));
                if activity.idle(arguments.idle) {
                    std::process::exit(0);
                }
            }
        });
    }
    let mut input = io::stdin();
    while let Some((kind, body, active)) = read_frame(&mut input, &activity) {
        if kind != 1 {
            break;
        }
        let value: Value = match serde_json::from_slice(&body) {
            Ok(value) => value,
            Err(_) => break,
        };
        // Read permanent envelope fields before attempting any version-specific record.
        let Some(id) = value.get("id").and_then(Value::as_u64) else {
            // A bad envelope must be answered, not silently end the service: every handle would become stale.
            writer.json(&json!({"contract": CONTRACT, "id": 0, "error": {
                "type": "malformed", "detail": "the request has no numeric id"
            }}));
            continue;
        };
        let Some(contract) = value.get("contract").and_then(Value::as_u64) else {
            writer.json(&json!({"contract": CONTRACT, "id": id, "error": {
                "type": "malformed", "detail": "the request has no contract"
            }}));
            continue;
        };
        if contract != u64::from(CONTRACT) {
            writer.json(&json!({"contract": CONTRACT, "id": id, "error": {
                "type": "contractMismatch", "contract": contract, "service": CONTRACT
            }}));
            continue;
        }
        if value.get("event").and_then(Value::as_str) == Some("answer") {
            if value
                .get("cancel")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                let _ = service.cancel_request(id);
            }
            continue;
        }
        let request: Request = match serde_json::from_value(value) {
            Ok(request) => request,
            Err(error) => {
                writer.json(&json!({"contract": CONTRACT, "id": id, "error": {"type": "malformed", "detail": error.to_string()}}));
                continue;
            }
        };
        if request.op == "cancel" {
            let target = request
                .operation
                .get("id")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            let cancelled = service.cancel_request(target);
            writer.json(&json!({"contract": CONTRACT, "id": id, "ok": {"cancelled": cancelled}}));
            continue;
        }
        let import = request.op == "import";
        let class = if import {
            2
        } else if is_bulk(&request.op) {
            0
        } else {
            1
        };
        let Some(permit) = gates.take(class) else {
            writer.reply(
                id,
                Err(Failure::busy("the service's work credits are full")),
            );
            continue;
        };
        // The cancel's one owner is this loop: registered before the import thread can run, removed after it.
        if import {
            service.register_cancel(id);
        }
        let service = service.clone();
        let writer = writer.clone();
        thread::spawn(move || {
            let _permit = permit;
            let _active = active;
            let outcome = service.run(&request, writer.as_ref());
            if import {
                service.finish_cancel(id);
            }
            writer.reply(id, outcome);
        });
    }
    // The parent closed or corrupted its private connection: kill all abandoned work with this process.
}

fn usage(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(64);
}

struct Arguments {
    data: Option<String>,
    cache: Option<String>,
    idle: Duration,
}
impl Arguments {
    fn parse() -> Self {
        let mut arguments = Self {
            data: None,
            cache: None,
            idle: Duration::from_secs(30),
        };
        let mut next = std::env::args().skip(1);
        while let Some(argument) = next.next() {
            match argument.as_str() {
                // A flag without its value is a caller's bug: defaulting silently would run memory-only, or with
                // another idle bound, and look like it worked.
                "--data" => {
                    arguments.data = Some(
                        next.next()
                            .unwrap_or_else(|| usage("--data needs a folder")),
                    )
                }
                "--cache" => {
                    arguments.cache = Some(
                        next.next()
                            .unwrap_or_else(|| usage("--cache needs a folder")),
                    )
                }
                "--idle" => {
                    let value = next
                        .next()
                        .unwrap_or_else(|| usage("--idle needs a number of seconds"));
                    let seconds = value
                        .parse::<u64>()
                        .unwrap_or_else(|_| usage("--idle needs a number of seconds"));
                    arguments.idle = Duration::from_secs(seconds);
                }
                other => {
                    eprintln!("unknown service argument {other}");
                    std::process::exit(64);
                }
            }
        }
        arguments
    }
}

fn read_frame(input: &mut impl Read, activity: &Arc<Activity>) -> Option<(u8, Vec<u8>, Active)> {
    let mut length = [0u8; 4];
    input.read_exact(length.get_mut(..1)?).ok()?;
    let active = activity.begin()?;
    input.read_exact(length.get_mut(1..)?).ok()?;
    let length = u32::from_le_bytes(length) as usize;
    if length > JSON_MAX {
        return None;
    }
    let mut kind = [0u8; 1];
    input.read_exact(&mut kind).ok()?;
    let mut body = vec![0u8; length];
    input.read_exact(&mut body).ok()?;
    Some((*kind.first()?, body, active))
}
