# opencode resolution and grounded-summary recovery

## Problem

Hushnote's fixed executable search order selects the Homebrew opencode 1.18.15
before the user's official `~/.opencode/bin/opencode` 1.18.18 installation.
The older binary presents as `opencode.exe` in Activity Monitor. Summary runs
also collapse malformed output and citation-validation failures into one generic
error, and discard a claim whose citations are valid when its prose is too
loosely paraphrased.

## Design

- Prefer user-scoped, vendor-specific CLI locations before package-manager
  locations while retaining the resolver's ownership and permissions checks.
- Keep exact segment-ID and verbatim-quote validation. If those citations pass
  but the model's claim prose does not, replace the prose with a bounded
  extractive sentence made only from the validated quotes.
- Distinguish undecodable provider output from unsupported citations.
- Return a validated extraction directly for a single transcript chunk. For
  multiple chunks, retain synthesis, but fall back to the already validated
  extraction facts if synthesis is malformed or loses its grounding.
- Never persist raw provider output or unvalidated prose.

## Verification

Add regression coverage for executable precedence, extractive recovery,
malformed-output diagnostics, single-chunk call count, and multi-chunk synthesis
fallback. No real transcript or quota-consuming CLI invocation is required.
