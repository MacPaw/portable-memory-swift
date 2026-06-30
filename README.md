# Portable Memory

**An open, vendor-neutral format and protocol for carrying AI memory across apps, devices, and vendors — losslessly, locally, and verifiably governed.**

A `.mem` bundle is a plain directory of JSONL streams + a manifest + checksums. No server is needed to read, verify, or transfer it. The format is a lossless **superset container**: foreign fields and entire foreign record kinds round-trip verbatim, so a memory can move *into* the standard and back out — or between vendors — without loss. Its conformance badge is **gated on deletion-propagation correctness**, the single hardest guarantee a memory layer makes.

This repository is the **specification** + the **Swift reference SDK**. [Mnemos](https://github.com/MacPaw/mnemos) is the reference adopter.

- 📄 **Spec:** [`Spec/portable-memory-spec.md`](Spec/portable-memory-spec.md)
- 🧬 **JSON Schemas:** [`Schemas/`](Schemas) (language-neutral; validate without Swift)
- ✅ **Conformance kit:** [`Conformance/`](Conformance)

## Install (Swift)

```swift
.package(url: "https://github.com/MacPaw/portable-memory-swift.git", from: "0.1.0")
```

```swift
import PortableMemory
```

## How adoption works

Implement one protocol — `PortableMemoryStore` — mapping your store to/from the portable record DTOs. The SDK owns the format: bundle I/O, the manifest, checksums, deterministic JSONL, **tombstone-first** import ordering, `--since` filtering, and `ext`/passthrough. You own persistence and re-deriving your own artifacts (indexes, embeddings) on import.

Every protocol requirement has a default (empty read / no-op write), so you override **only the kinds you support** — a store with just episodes implements two methods, not thirty.

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

Ingest another vendor's export with an adapter (ships with mem0):

```swift
let episodes = try Mem0Adapter.parseEpisodes(Data(contentsOf: mem0ExportURL))   // → [PortableEpisode]
```

## The bundle

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

## Deletion propagation — the trust core

A deletion is a first-class, portable **tombstone** that propagates to every artifact derived from the content (indexes, vectors, caches, graph edges, replicas) and records the **proof of what was removed**. Importers apply tombstones *before* additions, so a bundle that also ships the stale rows can never resurrect deleted content.

## Conformance levels

| Level | Requirement |
|---|---|
| **L0** | Read / Export — a valid, checksum-clean bundle |
| **L1** | Import / Merge — lossless, idempotent, bi-temporal merge |
| **L2** | **Deletion propagation** — honors tombstones across all derived artifacts (**badge**) |
| **L3** | Governed — full audit trail, Evidence Pack, signed tombstones |

## Cross-vendor

| `.mem` | mem0 | OpenAI / ChatGPT | Anthropic / Claude | Letta |
|---|---|---|---|---|
| `episode` | a memory | a saved memory / turn | a memory-tool entry | archival/recall message |
| `core` | — | profile | persona/project notes | core memory block |
| `entity`/`edge`/`fact` | graph relations | derive on import | derive on import | — |

What a source doesn't model rides in via `ext` (fields) and passthrough (kinds). New adapters map what's modeled and preserve the rest. See the spec §10.

## License

MIT.
