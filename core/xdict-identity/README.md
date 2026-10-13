# xdict-identity

What a dictionary is keyed by (ADR-0002): an **edition** is the SHA-256 of the whole `.mdx`, hashed in one pass
that also sums each 4 MiB chunk; a resource volume is recognised by a local **validation token**; a **lineage**
is minted once per new edition. A file's path is never its identity. The `Registry` trait holds lineages and
locations; `FileRegistry` keeps them in one JSON document, written by rename, refused rather than reset when it
cannot be read. The study ledger will implement the trait.
