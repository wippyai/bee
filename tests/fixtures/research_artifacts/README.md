# Reviewed research artifact

`canonical-json-v1.json` preserves the Gemini-authored dashboard and encoder,
with explicit host review changes recorded in `review_provenance`. Its measured
entry digest is `41ec83bf59ade1e7c9685245ae4a09847e738d0271921afe0488d2106552580f`.
The native runtime verifies the digest again before staging or applying it.
This MIT fixture is outside production packs.

Run from the repository root:

```sh
make research-measurement-check ARTIFACT=tests/fixtures/research_artifacts/canonical-json-v1.json
```

The check starts isolated stores and a native loopback MCP endpoint on an
automatically assigned port. An explicit test operator freezes, reviews and
approves the artifact; the tool subject cannot approve installation. The benchmark
uses the exact current source baseline, a fixed four-input corpus and seven
samples. Results are durable, producer-authenticated thread observations.
Ordinary agent messages cannot become benchmark observations.

The original baseline fails native large-integer correctness. A completed
timing run is not evidence of a valid speedup. Live Gemini invocation of this
measurement tool, dashboard acceptance and global installation remain
separate gates; this command does not claim them.

The second boot requires the existing automatic recovery service to restore the
exact approved artifact. A direct recovery call is diagnostic only and cannot
turn an automatic recovery failure into a passing check.
