//! The wire contract's fixtures through Rust: every line decodes, the envelope obeys the schema, and the request
//! and reply re-encode to themselves. `plan-windows-v1` WI-1; the service's own decode test is WI-4's.
use std::fs;

use serde_json::Value;

fn contract_dir() -> std::path::PathBuf {
    // .../apps/windows/contract/tests/rust -> .../apps/windows/contract
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

#[test]
fn every_fixture_decodes_and_re_encodes() {
    let schema: Value =
        serde_json::from_str(&fs::read_to_string(contract_dir().join("contract.json")).expect("contract.json"))
            .expect("contract.json decodes");
    let operations = schema["operations"].as_object().expect("operations");
    let mut errors: Vec<String> = Vec::new();
    for side in ["core", "wire"] {
        for error in schema["errors"][side].as_array().expect("errors") {
            errors.push(error.as_str().expect("an error name").to_string());
        }
    }

    let fixtures = fs::read_to_string(contract_dir().join("fixtures.jsonl")).expect("fixtures.jsonl");
    let mut count = 0;
    for line in fixtures.lines().filter(|line| !line.trim().is_empty()) {
        let pair: Value = serde_json::from_str(line).expect("a fixture line decodes");
        let name = pair["name"].as_str().expect("a name");
        let request = &pair["request"];
        let reply = &pair["reply"];

        assert_eq!(request["id"], reply["id"], "{name}: the id is echoed");
        let op = request["op"].as_str().expect("an op");
        assert!(operations.contains_key(op), "{name}: op {op} is in the schema");
        assert_eq!(reply["contract"].as_u64(), Some(1), "{name}: the reply's contract is 1");
        if request["contract"].as_u64() != Some(1) {
            assert_eq!(
                reply["error"]["type"].as_str(),
                Some("contractMismatch"),
                "{name}: an off-contract request is answered contractMismatch"
            );
        }
        if let Some(error) = reply.get("error") {
            let kind = error["type"].as_str().expect("an error type");
            assert!(errors.iter().any(|known| known == kind), "{name}: error {kind} is in the schema");
        }

        for (what, value) in [("request", request), ("reply", reply)] {
            let encoded = serde_json::to_string(value).expect("re-encodes");
            let reparsed: Value = serde_json::from_str(&encoded).expect("re-decodes");
            assert_eq!(&reparsed, value, "{name}: the {what} round-trips");
        }
        count += 1;
    }
    assert!(count >= 8, "the fixture set is {count}, expected at least 8");
}
