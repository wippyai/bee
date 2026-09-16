# Reviewed research artifact

`canonical-json-v1.json` preserves the Gemini-authored dashboard and encoder,
with explicit host review changes recorded in `review_provenance`. Its measured
entry digest is `dde4264479b2cd3d01472690d7f550183228f38c487d60f28e7611e0ec36e818`.
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
timing run is not evidence of a valid speedup. Global installation remains a separate gate. This offline command does not
invoke a provider. The physical desktop gate opens the installed app from
Start → Tools, checks both plotted medians against the native measurement log,
resizes to 70×24, exits cleanly, and requires the saved dashboard to return on
a second boot without reopening it.

The second boot requires the existing automatic recovery service to restore the
exact approved artifact. A direct recovery call is diagnostic only and cannot
turn an automatic recovery failure into a passing check.

To require the installed Gemini/Agy harness, using its normal user login:

```sh
make research-live-measurement-check ARTIFACT=tests/fixtures/research_artifacts/canonical-json-v1.json
```

This consumes provider inference. Gemini must request `research:measure` through
MCP itself. A separate test-operator scope approves only that exact attempt's
request through the durable inbox. The harness runs both measurements; the check
reads their actual attempt-bound observations and requires those newest values
in the dashboard and its automatic restoration. Harness messages and older HTTP
measurements cannot satisfy the live assertion. Fixtures retain private evidence
in the printed temporary directory and never alter the global Bee installation.
