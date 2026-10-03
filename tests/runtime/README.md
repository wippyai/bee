# Gateway race regressions

`gateway-policy-readiness.patch` is a proposed upstream Wippy fix against
`5eb9901870e3a7ca72b608fc0f5e70b531d914b6`. It is not selected by Bee's build
manifest. The pinned builder deliberately rejects runtime patches; shipping
this fix requires an upstream landing followed by a Bee runtime pin update.

The existing policy manager queues policy events and acknowledges its registry
entry before the policy registry applies them. The full shard regression
observes `policy not found` on the first gateway request after a successful
registry transaction, and a stale first lookup after policy restoration.
The patch waits for the existing policy owner's applied result. Missing owners,
cancellation and mutation errors return their causes; no retry or timer is added.

The patch includes a deterministic regression that cancels delivery while a
policy event is queued: the unpatched manager incorrectly reports success for
add, update and delete. Owner tests also cover the first read after each
completed mutation and propagation of missing-policy errors.

After applying the patch to that upstream checkout, run its affected Go tests
with an explicitly selected temporary directory outside `/tmp`:

```sh
mkdir -p .wippy/policy-proof-tmp
TMPDIR="$PWD/.wippy/policy-proof-tmp" GOWORK=off GOTOOLCHAIN=go1.27.0 \
  go test -race ./service/security/policy ./system/security ./boot/components/core
```

Bee's `make gateway-race-check TEST_JOBS=4` repeats all four full Lua shards
ten times and preserves every process's complete output under
`.wippy/gateway-race/`. It uses the unit runner's resource metadata grouping
and daemon-identity lock in the user's XDG cache. Each shard and round has
a disposable workspace, database set and selected loopback address. All requested rounds
run, and any failed shard makes the check fail, including Docker failures.
Each failure retains its original output even when later rounds pass.
`make lint` and `make fixture-lint` remain separate gates. The test runner
rejects skipped cases even when the upstream runner exits zero.

The Lua policy-reference test checks replacement and restoration on their
first lookups. The carrier readiness test queries the listener's initial
routes directly. The first-request regression removes all temporary grant,
policy and requirement entries after each successful request.

The carrier pause waiter observes pause acknowledgements, monitored exits and
cancellation. An exit before the requested step reports the original carrier
error immediately. Its regression crashes the carrier at `prepared` while the
caller awaits `attempt_started`.

The token-invalidation fixtures change the token while its carrier is lost,
then fence and resume a replacement before enforcing the child's stop. They
observe the runner's EXIT before reading the replacement's committed report.
Stopping before attaching a consumer can exhaust the declared output-retention
bound; the loaded regression records `output.lost` and no gateway report.
Default exit waits use supervision, and completed reports are read directly.
An explicit caller wait retains its declared bound.

The production carrier drains accepted hooks after each processed wake before
deciding to end the child session. The full shard crash regression exposes why
the ordering matters: terminal output can arrive before the periodic hook tick,
and placement reconciliation rejects unclaimed hooks when it revokes the binding.
