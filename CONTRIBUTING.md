# Contributing to Portable Memory

Thanks for helping build an open, vendor-neutral memory format. Contributions of every
kind are welcome — SDK code, new adapters, other-language implementations, spec
clarifications, and conformance fixtures.

## Ways to contribute

- **Implement the spec** in another language. The format is defined by
  [`Spec/portable-memory-spec.md`](Spec/portable-memory-spec.md) and the language-neutral
  [`Schemas/`](Schemas); you don't need this Swift SDK to interoperate.
- **Write an adapter** that maps another vendor's export into the model (see
  `Sources/PortableMemory/Adapters/Mem0Adapter.swift` for the pattern — map what's
  modeled, keep the rest in `ext`/`metadata` so a later export stays lossless).
- **Improve the SDK** — bug fixes, robustness, docs.
- **Propose a spec change** (see below).

## Building & testing

```sh
swift build
swift test
```

The suite must stay green on **macOS and Linux** (CI runs both). Please add a test with
any behavior change; the reference `InMemoryStore` in the test target shows the shape an
adopter implements.

## SDK changes vs spec changes

- **SDK change** (code/tests/docs, no wire-format impact): open a PR.
- **Spec change** (anything that alters the on-disk format, schemas, or a normative
  requirement): open an issue using the **Spec change** template first, so the design can
  be discussed before implementation. Format-affecting changes follow semver on the
  manifest `format` field and are decided per [`GOVERNANCE.md`](GOVERNANCE.md).

Keep the spec, the JSON Schemas, the Swift DTOs, and the sample fixture **in sync** — a PR
that changes one usually needs to touch the others. `swift test` validates the shipped
fixture; please also validate `Schemas/` against your samples.

## Conventions

- Match the surrounding style; keep the SDK dependency-light (currently only
  swift-crypto) and Linux-clean (Foundation + Crypto only).
- Canonical JSON rules are normative (spec §1.1) — don't introduce serialization that
  diverges from `MemCodec`.
- Update [`CHANGELOG.md`](CHANGELOG.md) under **Unreleased**.

## Developer Certificate of Origin (DCO)

We use the [DCO](https://developercertificate.org/) rather than a CLA. Sign off each
commit (`git commit -s`), certifying you have the right to submit it under the project's
MIT license:

```
Signed-off-by: Your Name <you@example.com>
```

By contributing, you agree your contributions are licensed under the repository's
[MIT license](LICENSE).
