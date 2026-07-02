# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The SDK package version is
independent of the on-disk **format** version (`format` in the manifest).

## [Unreleased]

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
  verbatim passthrough; `Mem0Adapter` for mem0 exports, `OpenAIAdapter` for the
  ChatGPT data export (`conversations.json` + a saved-memories fallback), and
  `ClaudeAdapter` for Claude memory files (`MEMORY.md` + topic files with
  frontmatter).
- **JSON Schemas** for every record kind, the manifest, tombstones, and the audit log.
- **Conformance kit** — L0–L3 checklist, deletion-propagation probe, and a sample `.mem`
  fixture (validated in CI).
- **Untrusted-input hardening** — path-traversal + symlink-escape rejection, unlisted-file
  rejection, and a per-file size bound (`MemLimits`).
- **CI** — `swift build` + `swift test` on macOS and Linux, plus a fixture-checksum check.

[Unreleased]: https://github.com/MacPaw/portable-memory-swift/commits/main
