# conformance

Language-neutral fixtures that prove every platform agrees: dictionary files written by the core's test
writer, each with its expected lookups as JSON, plus golden vectors for edition hashes, scheduling and
ledger migrations. Owned by the core; every platform runs them through its own binding in CI. No
dictionary content from anywhere else ever enters this folder. Not started.
