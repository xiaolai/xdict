//! The wire contract's fixtures through Rust: every line decodes, the envelope obeys the schema, and the request
//! and reply re-encode to themselves. `plan-windows-v1` WI-1; the service's own decode test is WI-4's.
use std::fs;

use serde_json::Value;

// The service's own wire module, compiled here unchanged: the fixture's request is decoded by the types the service
// decodes it with, so a field renamed or retyped on one side fails this test rather than only a live run.
#[path = "../../../../service/src/wire.rs"]
mod wire;

/// The body type each operation decodes into (`service/src/ops.rs`); an op absent here carries no body.
fn body(op: &str, operation: &Value) -> Result<(), serde_json::Error> {
    match op {
        "import" => serde_json::from_value::<wire::ImportBody>(operation.clone()).map(drop),
        "open" => serde_json::from_value::<wire::OpenBody>(operation.clone()).map(drop),
        "close" => serde_json::from_value::<wire::CloseBody>(operation.clone()).map(drop),
        "lookup" => serde_json::from_value::<wire::LookupBody>(operation.clone()).map(drop),
        "suggest" => serde_json::from_value::<wire::SuggestBody>(operation.clone()).map(drop),
        "entry" => serde_json::from_value::<wire::EntryBody>(operation.clone()).map(drop),
        "resource" => serde_json::from_value::<wire::ResourceBody>(operation.clone()).map(drop),
        "entryText" => serde_json::from_value::<wire::EntryTextBody>(operation.clone()).map(drop),
        "link" => serde_json::from_value::<wire::LinkBody>(operation.clone()).map(drop),
        "joinLineage" => serde_json::from_value::<wire::JoinLineageBody>(operation.clone()).map(drop),
        "splitLineage" => serde_json::from_value::<wire::SplitLineageBody>(operation.clone()).map(drop),
        "lineageOf" => serde_json::from_value::<wire::LineageOfBody>(operation.clone()).map(drop),
        "entryGloss" => serde_json::from_value::<wire::EntryGlossBody>(operation.clone()).map(drop),
        "ledgerRecord" => serde_json::from_value::<wire::LedgerRecordBody>(operation.clone()).map(drop),
        "ledgerHistory" => serde_json::from_value::<wire::LedgerHistoryBody>(operation.clone()).map(drop),
        "ledgerRemove" | "ledgerRestore" => {
            serde_json::from_value::<wire::LedgerRemovalBody>(operation.clone()).map(drop)
        }
        "eraseData" => serde_json::from_value::<wire::EraseBody>(operation.clone()).map(drop),
        "studyNote" => serde_json::from_value::<wire::StudyNoteBody>(operation.clone()).map(drop),
        "studyNoteAt" => serde_json::from_value::<wire::StudyNoteAtBody>(operation.clone()).map(drop),
        "definitionHash" => serde_json::from_value::<wire::DefinitionHashBody>(operation.clone()).map(drop),
        "studyReanchor" => serde_json::from_value::<wire::ReanchorBody>(operation.clone()).map(drop),
        "reviewQueue" => serde_json::from_value::<wire::QueueBody>(operation.clone()).map(drop),
        "reviewGrade" => serde_json::from_value::<wire::GradeBody>(operation.clone()).map(drop),
        "reviewUndo" => serde_json::from_value::<wire::UndoBody>(operation.clone()).map(drop),
        "reviewSummary" => serde_json::from_value::<wire::SummaryBody>(operation.clone()).map(drop),
        "reviewResolve" => serde_json::from_value::<wire::ResolveBody>(operation.clone()).map(drop),
        "ledgerSync" => serde_json::from_value::<wire::SyncBody>(operation.clone()).map(drop),
        "explore" => serde_json::from_value::<wire::ExploreBody>(operation.clone()).map(drop),
        "collocates" => serde_json::from_value::<wire::CollocatesBody>(operation.clone()).map(drop),
        "examples" => serde_json::from_value::<wire::ExamplesBody>(operation.clone()).map(drop),
        "phrases" => serde_json::from_value::<wire::PhrasesBody>(operation.clone()).map(drop),
        "setWordPack" => serde_json::from_value::<wire::SetWordPackBody>(operation.clone()).map(drop),
        "buildWordPack" => serde_json::from_value::<wire::BuildWordPackBody>(operation.clone()).map(drop),
        _ => Ok(()),
    }
}

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
    let contract = schema["contract"].as_u64().expect("the contract's number");
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

        // Through the service's own types: the envelope, every file record, and the operation's body.
        let decoded: wire::Request = serde_json::from_value(request.clone())
            .unwrap_or_else(|error| panic!("{name}: the service cannot decode the request: {error}"));
        assert_eq!(decoded.id, request["id"].as_u64().expect("an id"), "{name}: the id decodes");
        body(request["op"].as_str().expect("an op"), &request["operation"])
            .unwrap_or_else(|error| panic!("{name}: the operation body does not decode: {error}"));

        assert_eq!(request["id"], reply["id"], "{name}: the id is echoed");
        let op = request["op"].as_str().expect("an op");
        assert!(operations.contains_key(op), "{name}: op {op} is in the schema");
        assert_eq!(reply["contract"].as_u64(), Some(contract), "{name}: the reply's contract is the schema's");
        if request["contract"].as_u64() != Some(contract) {
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
    assert!(count >= 26, "the fixture set is {count}, expected at least 26");
}
