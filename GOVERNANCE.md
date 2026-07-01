# Governance

Portable Memory is an **open format proposal**, not a standard decreed by one company.
This document describes how it is stewarded today and how that is intended to evolve.

## Current model: open steward

MacPaw currently **stewards** the project: it maintains the reference SDK, the spec, and
the schemas, and it has final say on what merges. This is the honest state of a young
project with one reference implementation — not an endorsement of single-vendor control.
Everything happens in the open: public repo, public issues, public discussion, MIT
license.

## How decisions are made

- **Code changes** — proposed by PR, reviewed by a maintainer, merged by lazy consensus
  (no sustained objection) plus maintainer approval.
- **Spec / format changes** — proposed via a **Spec change** issue and discussed before
  implementation. Anything that alters the on-disk format, schemas, or a normative
  requirement is a spec change.
- **Versioning** — the on-disk `format` is semver (independent of the SDK package
  version). A **backward-compatible** addition bumps the minor; a **breaking** change
  bumps the major and requires a migration note. Unknown fields/kinds always round-trip,
  so minor additions never break older readers.

## Compatibility policy

- Readers preserve unknown fields (`ext`) and unknown kinds (passthrough) verbatim, so a
  newer bundle never loses data in an older reader.
- Deprecations are announced in [`CHANGELOG.md`](CHANGELOG.md) at least one minor format
  version before removal.

## Where this is headed

The goal is a genuinely neutral standard. As independent implementations and adopters
appear, we intend to:

1. Add **maintainers from outside MacPaw** (a contributor with sustained, high-quality
   involvement can be nominated).
2. Adopt a lightweight **RFC process** for format changes once there is more than one
   implementation to keep in sync.
3. Move the spec to a **vendor-neutral home** (a foundation or neutral org) when adoption
   justifies it.

If you are implementing Portable Memory in another language or product and want a say in
its direction, open an issue — that is exactly the involvement this project needs.

## Code of conduct

Participation is governed by the [Contributor Covenant](CODE_OF_CONDUCT.md).
