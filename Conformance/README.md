# Conformance kit

How to claim a Portable Memory conformance level, and how to check a bundle.

## Levels

| Level | Requirement | How to demonstrate |
|---|---|---|
| **L0** | Read / Export | `BundleValidator().validate(bundle:)` returns `ok` on your exported bundle. |
| **L1** | Import / Merge | Export → import into a fresh store reproduces counts/content; a second import is a no-op (idempotent). |
| **L2** | **Deletion propagation** (badge) | Delete an item, then prove it is unreachable via **every** route your engine supports + a tombstone was written (the probe below). |
| **L3** | Governed | Full audit trail + Evidence Pack export + signed tombstones. |

## Validate a bundle (L0)

```swift
let result = BundleValidator().validate(bundle: URL(fileURLWithPath: "path/to/bundle.mem"))
precondition(result.ok, result.issues.joined(separator: "\n"))
```

The validator checks: the manifest parses, every listed file matches its `sha256` and
byte count, no unlisted/injected files are present, and every known-kind stream
decodes. Unknown (vendor) kinds are intentionally opaque and pass through.

Language-neutral validation: the `Schemas/` JSON Schemas validate `manifest.json` and
each `items/<kind>.jsonl` record in any language.

## The deletion-propagation probe (L2 — the gate)

This is the guarantee the badge rests on. For each of a handful of distinctive
"needle" memories:

1. Add it; confirm it is retrievable.
2. Delete it.
3. Assert it is unreachable via **every** route your engine exposes — at minimum:
   dense vector search, lexical/full-text, any k-hop graph, any embedding/derived
   cache, the bi-temporal `as_of` historical view, and any synced replica.
4. Assert a portable tombstone was written for it (positive proof, not mere absence).

A conformant `delete` reaches every artifact derived from the content; a conformant
`import` applies tombstones **before** additions, so a bundle that still carries the
stale rows can never resurrect deleted content.

The reference adopter ([Mnemos](https://github.com/MacPaw/mnemos)) implements this as
`memctl eval propagation` across its real retrieval routes.

## Fixtures

`fixtures/sample.mem/` is a small, valid bundle exercising episodes, an entity, an
edge, an episode carrying a foreign `ext` field, a vendor-specific passthrough kind,
and a tombstone (with proof-of-reach). Use it to test your importer and validator.
