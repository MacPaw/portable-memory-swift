# Portable Memory

**An open, vendor-neutral format and protocol for carrying AI memory across apps, devices, and vendors — losslessly, locally, and verifiably governed.**

AI assistants are starting to *remember* — your preferences, your projects, your history across sessions. Portable Memory is the open standard for that memory: a `.mem` bundle is a plain folder of JSONL files + a manifest + checksums that any tool can read, verify, transfer, and merge. No server, no lock-in, no proprietary blob.

```text
your-memory.mem/
  manifest.json     items/episode.jsonl     audit/tombstones.jsonl     CHECKSUMS
```

---

## Why this exists

Today, the memory an assistant builds up about you is **trapped**. Every product stores it in its own private shape, in its own database, on its own servers:

- **You can't move it.** Switch assistants or devices and you start from zero — years of context, gone.
- **There's no shared meaning.** One vendor's "memory" is a text blob, another's is a graph, a third's is a chat log. Nothing speaks to anything else.
- **You can't prove it's deleted.** Ask to forget something and it may linger in a vector index, an embedding cache, a knowledge graph, or a backup replica. "Deleted" is a promise, not a guarantee.

This is the data-portability gap of the AI era — the same gap the web closed for documents, mail, and calendars with open formats. Memory is more personal and higher-stakes, and it deserves the same: **a format you own, that moves with you, and that deletes when you say so.**

## What you get

| For people | For builders | For the industry |
|---|---|---|
| **Own your memory.** Export it, keep a local copy, move it between assistants and devices. | **Adopt, don't reinvent.** Implement one small protocol and exchange memory with any other adopter. | **No lock-in.** A neutral, local-first standard instead of N proprietary silos. |
| **Real deletion.** A delete propagates to *every* derived copy, with verifiable proof (GDPR / EU AI Act). | **Trust & compliance for free.** Inherit verifiable deletion, an audit trail, and an Evidence Pack you can hand to a compliance team. | **An ecosystem.** Interop is the substrate for portable, composable AI memory. |
| **Inspect it.** Plain text + checksums — open it in any editor. | **Lossless on-ramp.** Foreign fields and record kinds round-trip verbatim, so adopting never costs you data. | **A conformance bar.** A badge that *means* something, gated on the hardest guarantee. |

## What makes it trustworthy

Three properties set this apart from "just another export schema":

1. **Verifiable deletion is the headline, not a footnote.** A deletion is a first-class, portable **tombstone** that propagates to every artifact derived from the content — indexes, vectors, caches, graph edges, replicas — and records *proof of what was removed*. The conformance badge is **gated on this** (level L2): you must prove a deleted item is unreachable via every retrieval route, not merely "removed from a table."
2. **Lossless superset, not a lowest common denominator.** A memory can move *into* the standard and back out — or between two vendors — without losing anything. Fields the standard doesn't model are preserved as `ext`; entire vendor-specific record kinds round-trip **verbatim**.
3. **Local-first and inspectable.** A bundle is a self-contained directory of JSONL + a manifest + a `CHECKSUMS` file. No server is needed to read, verify, or transfer it; source text is the portable truth and embeddings are an optional, model-tagged accelerator the receiver re-derives — so a bundle is never tied to one embedding model.

### Design principles

Vendor-neutral · local-first · lossless round-trip · **governed** (deletions propagate and are provable) · engine-agnostic (source text is authoritative) · auditable (every mutation logged).

---

## How it works

The format is a `.mem` bundle; the protocol is one Swift protocol you implement.

```text
mybundle.mem/
  manifest.json            format version, capabilities, model tags, counts, integrity
  items/<kind>.jsonl       episode, entity, edge, fact, resource, chunk, core, procedure,
                           context, community, category, preference, secretRef (+ vendor kinds)
  embeddings/              OPTIONAL, model-tagged; receiver may ignore and re-embed
  audit/log.jsonl          every mutation (provenance trail)
  audit/tombstones.jsonl   deletions + redactions — applied FIRST on import
  CHECKSUMS                sha256 per file
```

Implement `PortableMemoryStore` — map your store to/from the portable record DTOs. The SDK owns the format (bundle I/O, manifest, checksums, deterministic JSONL, **tombstone-first** import ordering, `--since` filtering, `ext`/passthrough, path-safety). You own persistence and re-deriving your own indexes/embeddings on import. Every requirement has a default (empty read / no-op write), so you override **only the kinds you support** — a store with just episodes implements two methods, not thirty.

```swift
struct MyStore: PortableMemoryStore {
    func exportEpisodes() async throws -> [PortableEpisode] { /* map your rows */ }
    func importEpisode(_ e: PortableEpisode, ext: String?) async throws { /* upsert by id */ }
    // …override the kinds you have; the rest default to no-op.
}

let manifest = try await BundleExporter().export(MyStore(), to: bundleURL)         // write a .mem
let report   = try await BundleImporter().importBundle(MyStore(), from: bundleURL)  // merge one in
let result   = BundleValidator().validate(bundle: bundleURL)                        // L0 check
```

Ingest another vendor's export with an adapter (mem0 ships in the box):

```swift
let episodes = try Mem0Adapter.parseEpisodes(Data(contentsOf: mem0ExportURL))   // → [PortableEpisode]
```

## Deletion propagation — the trust core

This is the guarantee the whole standard rests on. A `delete` (or `redact`, for erasure) must reach **everything** derived from the content, and an import must apply tombstones **before** additions — so a bundle that still ships the stale rows can never resurrect deleted content. The tombstone carries the proof-of-reach (the ids of every artifact removed), which is exactly what an Evidence Pack turns into a compliance artifact.

## Conformance levels

| Level | Requirement |
|---|---|
| **L0** | Read / Export — a valid, checksum-clean bundle |
| **L1** | Import / Merge — lossless, idempotent, bi-temporal merge |
| **L2** | **Deletion propagation** — honors tombstones across all derived artifacts (**the badge**) |
| **L3** | Governed — full audit trail, Evidence Pack, signed tombstones |

## Cross-vendor interoperability

The format is a superset container that absorbs other providers' memory without loss:

| `.mem` | mem0 | OpenAI / ChatGPT | Anthropic / Claude | Letta |
|---|---|---|---|---|
| `episode` | a memory | a saved memory / turn | a memory-tool entry | archival/recall message |
| `core` | — | profile | persona/project notes | core memory block |
| `entity` / `edge` / `fact` | graph relations | derive on import | derive on import | — |

What a source doesn't model rides in via `ext` (fields) and passthrough (kinds); new adapters map what's modeled and preserve the rest. Full mapping in the spec §10.

---

## Install

```swift
.package(url: "https://github.com/MacPaw/portable-memory-swift.git", from: "0.1.0")
```

```swift
import PortableMemory
```

Dependency-light (only [swift-crypto](https://github.com/apple/swift-crypto)), so it builds on Apple platforms **and** Linux.

## What's in this repo

| | |
|---|---|
| 📦 **`Sources/PortableMemory/`** | The Swift reference SDK — format types, DTOs, the `PortableMemoryStore` seam, `BundleExporter` / `BundleImporter` / `BundleValidator`, tombstones, and the mem0 adapter. |
| 📄 **[`Spec/portable-memory-spec.md`](Spec/portable-memory-spec.md)** | The language-neutral specification (v1.0). |
| 🧬 **[`Schemas/`](Schemas)** | JSON Schemas — validate `manifest.json` and each record kind in **any** language, no SDK required. |
| ✅ **[`Conformance/`](Conformance)** | The L0–L3 checklist, the deletion-propagation probe, and a sample `.mem` fixture. |

**Status:** spec v1.0; this is the reference SDK. [Mnemos](https://github.com/MacPaw/mnemos) is the reference adopter. Anyone — any vendor, any language — is welcome to implement the spec and the JSON Schemas; the goal is for the standard to grow *outward* across the ecosystem.

## License

MIT — use it, build on it, ship it.
