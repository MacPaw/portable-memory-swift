# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The SDK package version is
independent of the on-disk **format** version (`format` in the manifest).

## [Unreleased]

### Added

- **Format 1.1.0** — the manifest gains four optional fields (spec §3.1): `specURL`,
  `coverage` (`{from, to}` — earliest/latest episode `eventTime`), `scopes` (sorted
  context ids the records reference) and `bundleDigest` (sha256 of the exact `CHECKSUMS`
  bytes — one hash for the whole archive). The exporter emits them; the validator
  recomputes `bundleDigest` when present. 1.0 bundles remain valid — the shipped 1.0
  fixtures double as backward-compatibility tests. `MemCoverage` is a public type.

## [0.2.0] - 2026-09-14

### Added

- **README "Try it in 60 seconds"** with a demo GIF of the paste → validate → render flow.
- **`TransferTextAdapter`** — parses the pasted memory-transfer text that ChatGPT, Claude,
  and Gemini exchange today (the standard export prompt's `[date saved, if available] -
  memory content` entries in a code block; tolerant of `-`/`–`/`—`/`:` separators, bullets
  and numbering, section headers, bare ISO dates, month-name dates, indented continuation
  lines, and plain prose summaries) into **deterministic, deduplicated** episodes with the
  date, section, and line preserved verbatim in `transfer_*` metadata — and renders any
  episodes back into paste-ready text (`renderText`). The parsing rules mirror the Python
  SDK line-for-line; the shared fixture `Conformance/fixtures/transfer/` pins
  byte-identical output across both reference SDKs.

## [0.1.2] - 2026-09-13

### Added

- **Paper citation** — README callout and *Citation* section (BibTeX), `CITATION.cff` for
  GitHub's "Cite this repository", and a paper link in the spec header (the spec stays
  byte-identical with the Python repository). Paper:
  <https://research.macpaw.com/publications/portable-memory>.

## [0.1.1] - 2026-07-03

### Added

- **`OpenAIAdapter`** for the ChatGPT data export (`conversations.json` + a saved-memories
  fallback) and **`ClaudeAdapter`** for Claude memory files (`MEMORY.md` + topic files with
  frontmatter). Whatever a source models that the format does not is preserved in
  namespaced metadata.
- **Conformance golden vectors** — `Conformance/vectors/canonical-json.json` pins the
  Canonical JSON rules as `input → canonical bytes → sha256` cases (reproduced by
  `ConformanceVectorsTests`), plus a **signed fixture** (`signed.mem`, TEST key only) for
  cross-implementation signature verification.
- **Coverage expansion** — all-kinds round-trip, incremental (`since`) semantics, Evidence
  Pack, redact, and adapter edge cases (graph relations ignored, multimodal parts,
  regeneration branches).

### Fixed

- **64-bit integer parity** — `ext` values above `Int64.max` keep full precision
  (`JSONValue` gained a `UInt64` tier) instead of being widened to `Double`.
- **`Mem0Adapter`** aligned with mem0's documented export shapes: `expiration_date` and
  `attributed_to` are read, unrecognized keys are swept into metadata losslessly, and a
  string-valued `categories` no longer iterates character by character.
- **`OpenAIAdapter`** — precise JSON-boolean detection when parsing timestamps on Darwin
  (`NSNumber` 0/1 was misread as `Bool`, dropping `create_time`).
- Spec unified byte-for-byte across both repositories; cross-links to the Python SDK.

## [0.1.0] - 2026-07-01

First public release of the Portable Memory format (`format` **1.0.0**) and the Swift
reference SDK.

### Added

- **Format spec** (`Spec/portable-memory-spec.md`, v1.0), including normative sections for
  Canonical JSON (§1.1), integrity files (§1.2), optional Ed25519 signatures (§1.3), the
  identity & merge algorithm (§4.1), delete/redact receiver obligations (§5), and a prior
  art comparison (§12).
- **Swift SDK** — `BundleExporter` / `BundleImporter` / `BundleValidator`, the
  `PortableMemoryStore` protocol seam, canonical `MemCodec`, and DTOs for all record
  kinds.
- **Deletion propagation (L2)** — portable tombstones with proof-of-reach, applied before
  additions; no-resurrection enforced for **every** kind (not just episodes).
- **Ed25519 signing (L3)** — detached bundle signatures (`manifest.sig`) and tombstone
  signatures, verified against caller-supplied trusted keys.
- **Cross-vendor losslessness** — foreign episode fields via `ext` and foreign kinds via
  verbatim passthrough; `Mem0Adapter` for mem0 exports.
- **JSON Schemas** for every record kind, the manifest, tombstones, and the audit log.
- **Conformance kit** — L0–L3 checklist, deletion-propagation probe, and a sample `.mem`
  fixture (validated in CI).
- **Untrusted-input hardening** — path-traversal + symlink-escape rejection, unlisted-file
  rejection, and a per-file size bound (`MemLimits`).
- **CI** — `swift build` + `swift test` on macOS and Linux, plus a fixture-checksum check.

[Unreleased]: https://github.com/MacPaw/portable-memory-swift/compare/0.2.0...HEAD
[0.2.0]: https://github.com/MacPaw/portable-memory-swift/compare/0.1.2...0.2.0
[0.1.2]: https://github.com/MacPaw/portable-memory-swift/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/MacPaw/portable-memory-swift/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/MacPaw/portable-memory-swift/releases/tag/0.1.0
