# Portable Memory — Specification v1.0

> MacPaw Research · An open, vendor-neutral format for AI memory portability.
> Status: **v1.0**. Reference SDK: this repository (`PortableMemory`, Swift).
> Reference adopter: [Mnemos](https://github.com/MacPaw/mnemos).

**Goal.** Define an open, vendor-neutral format and protocol for carrying AI memory
across apps, devices, and vendors — losslessly, locally, and **verifiably governed**.
This is the differentiating component of the *Own Portable Memory* direction: the
asset that turns a memory layer from a feature into infrastructure. The format is
publishable as a standard others can adopt, and its conformance badge is **gated on
deletion-propagation correctness** — the single hardest guarantee a memory layer
makes.

This document specifies the on-disk format (`.mem` bundle), the data model, the
export/import/merge protocol, the deletion-and-redaction propagation guarantee, the
governance artifacts, and the conformance levels. It is written to be implementable
by any vendor in any language; the Swift `PortableMemory` package in this repo is the
reference implementation, and `Schemas/` carries language-neutral JSON Schemas.

---

## 0. Design principles

- **Vendor-neutral** — Readable/writable with no proprietary dependency. Plain JSONL
  + a JSON manifest. No database engine, no binary container required.
- **Local-first** — A bundle is a self-contained set of files. No server is required
  to read, verify, or transfer it.
- **Lossless round-trip** — `export → import` preserves facts, time, links,
  provenance, lifecycle state, and unknown fields.
- **Governed** — Deletions and redactions propagate to every replica and derived
  artifact, and are **provable**.
- **Engine-agnostic** — Source text is mandatory and authoritative; embeddings are
  optional and model-tagged. Receivers re-embed.
- **Auditable** — Every record carries provenance; every mutation is logged in a
  portable trail.

---

## 1. The container — a `.mem` bundle

A bundle is a directory (optionally packaged as a single archive). JSONL streams keep
it scalable and append-friendly; the manifest declares everything an importer needs
to negotiate capabilities and verify integrity.

```text
mybundle.mem/
  manifest.json            format version, source, capabilities, model tags, counts, integrity
  items/
    episode.jsonl          one JSON object per line; the file name is the kind discriminator
    entity.jsonl
    edge.jsonl             semantic relations (bi-temporal)
    fact.jsonl             derived subject–predicate–object triples
    factLink.jsonl
    episodeLink.jsonl
    resource.jsonl
    chunk.jsonl
    core.jsonl             always-injected profile blocks
    procedure.jsonl
    context.jsonl
    community.jsonl
    category.jsonl
    preference.jsonl
    secretRef.jsonl        vault references — encryption metadata only, NEVER plaintext
  embeddings/              OPTIONAL, model-tagged, id-parallel; receiver may ignore
    <table>.<model>.vec
  audit/
    log.jsonl              every mutation (provenance trail)
    tombstones.jsonl       deletions + redactions — applied FIRST on import
  CHECKSUMS                sha256 per file (sha256sum-compatible)
```

Only non-empty `items/<kind>.jsonl` files are written; a missing file means zero
records of that kind. Serialization is **deterministic**: records are ordered by id,
JSON object keys are sorted, slashes are unescaped, and timestamps are ISO-8601 —
so bundles are diffable.

**Lossless superset (cross-vendor).** To carry any vendor's memory without loss, the
container preserves what this engine doesn't natively model: **foreign fields** on the
episode record survive via an `ext` carrier (any key not in the native schema is kept
and re-emitted), and **entire foreign kinds** (`items/<vendorKind>.jsonl`) round-trip
**verbatim**. A bundle is therefore a superset container, not a lowest-common-denominator
one — see §10.

---

## 2. The data model — items by kind

Every memory is a record in `items/<kind>.jsonl`. The seven-component model (Working /
Core / Episodic / Semantic / Procedural / Resource / Vault) maps onto these kinds.
Vendors **may** add kinds; unknown kinds round-trip verbatim.

| `kind` | Payload | Notes |
|---|---|---|
| `episode` | A timestamped event — the atomic memory | Bi-temporal (`eventTime`, `mentionTime`, `ingestionTime`); carries `lifecycleState`, `sensitivity`, `pinned`, `deletedAt`. |
| `entity` | A semantic graph node | person / org / project / place / product / document / topic. |
| `edge` | A bi-temporal relation | `tValidFrom` / `tValidTo` / `supersededBy` / `evidenceEpisodeIDs`. |
| `fact` | A derived subject–predicate–object triple | Non-destructive reconciliation layer; bi-temporal + prune marker. |
| `factLink` | `evidence_of` / `refines` link between facts | |
| `episodeLink` | A-Mem cross-link between episodes | |
| `resource` | A file/doc reference | Parent of `chunk`s; `contentHash` + `uri`. |
| `chunk` | A resource fragment | Re-embeddable from `text`. |
| `core` | An always-injected profile block | human / persona. |
| `procedure` | A user-defined routine | Trigger + steps. |
| `context` / `community` / `category` / `preference` | Scoping, clustering, taxonomy, durable settings | |
| `secretRef` | A reference to a vault secret | **Never** carries plaintext or ciphertext (§7). |

### Identity, time & provenance

- **Stable IDs** — globally unique, kind-prefixed (`ep_`, `ent_`, `edge_`,
  `fact_`, …). The same id across systems denotes the same memory; this is what makes
  merge and deletion idempotent.
- **Bi-temporal facts** — edges and facts carry `tValidFrom` / `tValidTo` /
  `supersededBy`. Updates **supersede, never overwrite**: keep both rows, set
  `tValidTo` on the old one. A point-in-time view reconstructs any past state — no
  information loss.
- **Provenance** — edges carry `evidenceEpisodeIDs`; facts carry `episodeID`. Every
  derived assertion ties back to the episodes that justify it. Required for the
  Evidence Pack (§7).

### Embeddings & engine-agnostic representation

Vectors are model-specific and therefore **not** the portable truth — the source text
is. Embeddings are an optional accelerator.

- `content` / `text` is always carried; embeddings, when present, live in
  `embeddings/<table>.<model>.vec` with the model tag and dimension declared in the
  manifest.
- An importer **may** reuse vectors only when its model tag matches exactly;
  otherwise it **re-embeds from source text**. Never assume cross-model vector
  compatibility.
- The reference implementation (v1.0) does not inline vectors
  (`embeddingsIncluded: false`); the receiver re-embeds on import, restoring vector
  search without any cross-model risk.

---

## 3. The manifest

```jsonc
{
  "format": "1.0.0",
  "generator": "mnemos/0.18",
  "conformanceLevel": "L2",
  "createdAt": "2026-06-30T00:00:00Z",
  "exportMode": "full",            // or "incremental" with "since"
  "schemaVersion": 12,
  "embeddingModel": "bge-m3",
  "embeddingDim": 1024,
  "embeddingsIncluded": false,     // false ⇒ receiver re-embeds from source text
  "capabilities": ["bitemporal", "tombstones", "redaction", "evidence-pack"],
  "counts": { "episode": 128, "edge": 64, "tombstone": 3 },
  "files": [ { "path": "items/episode.jsonl", "sha256": "…", "bytes": 40213 } ]
}
```

`format` is semver. `capabilities` declares optional features. Importers negotiate by
capability and **preserve unknown kinds verbatim** + **foreign episode fields via
`ext`** on round-trip (§10), so a newer or other-vendor bundle never loses data here.

---

## 4. Operations — export & import / merge

- **Export** — full, or incremental (`--since <cursor>`) emitting only items +
  tombstones changed since the cursor. Deterministic ordering for diffable bundles.
- **Import** — idempotent and **merge-by-id**. Re-importing the same bundle converges
  to an identical store (a no-op in effect). Conflicts resolve by bi-temporal
  supersession; cardinality-1 relations supersede, never silently overwrite.
- **Order of operations on import** (strict):
  1. **Verify** the manifest and re-hash every file against `files[].sha256`; abort on
     mismatch (a tampered or corrupt bundle never half-applies).
  2. **Apply tombstones FIRST** (`audit/tombstones.jsonl`). This guarantees that even
     if the bundle also ships the (stale) rows, the subsequent merge will not
     resurrect deleted content, and redaction wins.
  3. **Merge items by id**, parents before children.
  4. **Re-derive** local artifacts: FTS index, sentence segmentation, and embeddings
     (re-embed from text when no matching vectors are carried). Imported data is
     first-class, not second-tier.
  5. Converge the synced replica.

---

## 5. Deletion & redaction propagation — the trust core

This is the guarantee the whole standard rests on, and the conformance gate. A
deletion is not a row removal; it is a **tombstone** that propagates everywhere the
data — or anything derived from it — ever went.

```jsonc
// audit/tombstones.jsonl — first-class, portable, monotonic (cannot be un-seen)
{
  "id": "tomb_01J…",
  "op": "delete",                  // "delete" | "redact"
  "targetKind": "episode",
  "targetID": "ep_01J9X…",
  "deletedAt": "2026-06-30T…Z",
  "reason": "GDPR erasure request",
  "actor": "ivan@…",
  "derived": {                     // proof-of-reach: what was actually removed
    "sentenceIDs": ["…"],
    "factIDs": ["…"],
    "edgeIDs": ["…"],              // edges deleted because their last evidence was removed
    "entityIDs": ["…"],           // entities orphaned by those edge deletions
    "embeddingCacheKeys": ["…"],  // content-hash cache entries evicted
    "episodeLinkCount": 2
  },
  "signature": "ed25519:…"         // optional (L3)
}
```

- **Delete** removes the item **and every derived artifact**: the FTS rows, the dense
  embedding, the **content-hash-keyed embedding cache**, the sentence index, graph
  edges evidenced only by it, the entities those orphan, A-Mem links, access history,
  and the synced replica copy.
- **Redact** additionally purges the content text while keeping the tombstone, so the
  deletion itself remains provable without retaining the content.
- **Propagation** — importers apply tombstones **before** additions. Every replica and
  external adopter must honor them. A synced replica is just another target that must
  converge.

> **Conformance probe (the L2 gate).**
> Issue a delete, then assert the content is unreachable via **every** route the host
> supports: dense vector search, lexical/full-text, the k-hop graph, any embedding
> cache, the bi-temporal `as_of` historical view, and the synced replica — and that a
> portable tombstone was written. (In the reference adopter this is `memctl eval
> propagation`.) A bundle that ships a conformance badge with this probe failing turns
> a trust asset into a liability the moment a user tests it.

---

## 6. Governance & the Evidence Pack

Every mutation appends to `audit/log.jsonl` as `(ts, actor, op, targetID, reason)`.
The **Memory Evidence Pack** is an exportable, procurement-grade subset — provenance
(`provenance/edges.jsonl`) + audit (`audit/log.jsonl`) + **proof-of-deletion**
(`audit/tombstones.jsonl`, each tombstone carrying the ids of every derived artifact
removed as of a timestamp) — formatted for IT/compliance and SIEM ingestion. This is
what converts "governed memory" from a claim into a buyable artifact under the EU AI
Act. Produced by `BundleExporter.exportEvidencePack(_:to:)` (in the reference adopter,
`memctl evidence-pack <dir>`).

---

## 7. Security & vault handling

- Secrets are **never** exported as plaintext or ciphertext — only a `secretRef` with
  encryption metadata. The encrypted value stays in the originating vault unless an
  explicit, authorized, encrypted transfer is negotiated. Import restores the metadata
  skeleton only and warns.
- Bundles may be encrypted at rest (envelope). `vault_must_stay_local` is honored
  across export and sync.
- Local-first by default; replica/sync is opt-in, regional where required, and **must
  propagate tombstones**.

---

## 8. Conformance levels & the badge

| Level | Requirement | What it proves |
|---|---|---|
| **L0** | Read / Export | Produces a valid, checksum-clean bundle. |
| **L1** | Import / Merge | Ingests losslessly, idempotently, with bi-temporal merge. |
| **L2** | Deletion propagation | Honors tombstones across all derived artifacts; passes the §5 probe. **Badge requires L2.** |
| **L3** | Governed | Full audit trail, Evidence Pack export, signed tombstones. |

The Swift reference SDK passes L0–L2 offline (`swift test` proves the lossless
idempotent round-trip, tombstone-first ordering, foreign-field/kind passthrough, and
tamper rejection); the reference adopter ([Mnemos](https://github.com/MacPaw/mnemos))
adds the live L2 deletion-propagation probe across its real retrieval routes and the
L3 Evidence Pack.

---

## 9. Versioning & capability negotiation

- `format` is semver in the manifest. `capabilities[]` declares features (e.g.
  `bitemporal`, `tombstones`, `redaction`, `evidence-pack`, `embeddings:<model>`).
- Importers negotiate by capability and **preserve unknown kinds verbatim** and
  **foreign fields on the episode record (via `ext`)** on round-trip, so a newer or
  other-vendor bundle never loses data in this reader (§10).

---

## 10. Vendor interoperability

The format is a **superset container**: it absorbs another provider's memory and
carries whatever it doesn't natively model, so a memory can move *into* the standard
and back out without loss. Two mechanisms make this concrete:

- **`ext` (foreign fields).** On import, any key on an `episode` record that is not in
  the native schema is captured and re-emitted on export. Nothing a vendor attached to
  a memory is dropped.
- **Passthrough (foreign kinds).** An `items/<vendorKind>.jsonl` whose kind this engine
  doesn't recognize is stored raw and re-emitted byte-for-byte.

**Adapters** map a foreign export onto the model on ingest; unmapped fields are kept in
`metadata` (namespaced) so a later `.mem` export stays lossless:

```swift
let episodes = try Mem0Adapter.parseEpisodes(data)   // ships in the reference SDK
// reference adopter CLI: memctl import ./mem0_export.json --from mem0
```

### Mapping reference

| `.mem` | mem0 | OpenAI / ChatGPT memory | Anthropic / Claude memory | Letta (MemGPT) |
|---|---|---|---|---|
| `episode` | a memory (`memory`, `created_at`, `user_id`/`agent_id`/`run_id`, `categories`) | a saved memory string / conversation turn | a memory-tool file entry | archival/recall message |
| `core` | — | "what ChatGPT knows about you" profile | persona/project memory notes | core memory block (human/persona) |
| `entity` / `edge` / `fact` | mem0 graph relations | — (derive on import) | — (derive on import) | — |
| `procedure` | — | custom instructions | — | — |
| `secretRef` | — | — | — | — |
| provenance | `user_id`/`agent_id`/`run_id`/`role` → actors + `metadata` | author/source | source file | sender/role |

Kinds a source lacks are simply absent; kinds a source has that the standard lacks ride
in via `ext`/passthrough. New adapters (ChatGPT export, Claude memory files, Letta) plug
in the same way — map what's modeled, preserve the rest. This is what lets the standard
grow *outward* across vendors instead of forcing a lossy common subset.

---

## 11. Worked example — a minimal bundle

```jsonc
// manifest.json (excerpt)
{ "format": "1.0.0", "generator": "mnemos/0.18", "conformanceLevel": "L2",
  "counts": { "episode": 1, "edge": 1, "tombstone": 1 } }
```

```jsonc
// items/edge.jsonl — a bi-temporal edge superseded, not overwritten
{ "id": "edge_a1", "srcEntityID": "ent_q3", "dstEntityID": "ent_may30",
  "edgeType": "launch_date", "tValidFrom": "2026-01-10T00:00:00Z",
  "tValidTo": "2026-06-30T00:00:00Z", "supersededBy": "edge_a2",
  "evidenceEpisodeIDs": ["ep_7"], "confidence": 0.9, "ingestionTime": "2026-01-10T00:00:00Z" }
```

```jsonc
// audit/tombstones.jsonl
{ "id": "tomb_1", "op": "delete", "targetKind": "episode", "targetID": "ep_legacy7",
  "deletedAt": "2026-06-30T00:00:00Z", "reason": "user erasure", "actor": "user",
  "derived": { "factIDs": ["fact_3"], "edgeIDs": ["edge_9"], "entityIDs": [],
               "sentenceIDs": ["sent_3"], "embeddingCacheKeys": ["…"], "episodeLinkCount": 0 } }
```

---

*v1.0 grounded in the Mnemos / Mnemonix architecture and the Portable-scenario win
conditions from MacPaw strategic-foresight simulations: publish an open cross-vendor
memory-portability standard first; gate the conformance badge on deletion-propagation
correctness; keep the stack engine-agnostic and local-first.*
