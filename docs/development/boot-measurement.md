# Standalone boot measurement

Build with `make standalone`, preserve the previous executable, then run:

```sh
make boot-measure BOOT_PREVIOUS_BEE=/path/to/previous/bee BOOT_RECORD=1
make boot-measure BOOT_PREVIOUS_BEE=/path/to/previous/bee
```

`BOOT_BASELINE` names the baseline JSON (default
`.wippy/boot-measure/baseline.json`); `BOOT_RUNS` defaults to three. Recording
never replaces an existing baseline. Comparison requires the same CPU model,
CPU count, architecture and operating system, and fails when any scenario's
median increases by more than 20 percent. This opt-in performance gate stays
outside `make test`; its deterministic comparison tests run in `make test`.
Incomplete or nonfinite timing sets cannot pass comparison.

Every scenario uses an empty caller directory, an isolated home and an explicit
state directory under `.wippy/boot-measure/run-*`. Fresh starts an empty state;
attach reuses its live owner; warm restarts the stopped owner; upgrade starts
the current executable against a stopped state created by the previous
executable. States, executable digests, PTY output, original log timestamps and
results remain available for inspection. The harness stops every owner it starts.
The previous executable must have a different digest.
Boot checks classify startup from output captured before cleanup. Stopping a
retained owner closes its viewport and revokes the attached physical client's
mount; that client can then report `terminal mount expired or revoked`.
An error caused by the check's own shutdown does not establish a startup failure.
Keep startup and cleanup captures separately, and preserve any startup refusal
even when a desktop frame also appears. The external owner-copy harness accepts
an optional source-state argument for disposable fixtures; exercise it with
`python3 tests/owner_boot_check_regression.py /path/to/owner_boot_check.sh`.
The existing runtime cache-statistics diagnostic records compile/typecheck hits
and misses on owner shutdown; a fresh owner's counters also include the attach
sample performed during that same owner lifetime.

The harness requests nice 0 and verifies it. It rejects a run if any of the
one-, five- or fifteen-minute load averages exceeds half the logical CPU count
before or after any sample. `BOOT_DIAGNOSTIC=1` retains contaminated samples
and fails; those samples cannot establish or pass a baseline. Arrange a quiet
window before recording, and avoid concurrent builds during measurement.

The first-frame timestamp observes the first complete synchronized output frame
containing the Desktop header. Plain routing text does not count. Desktop
readiness is a separate observation, so an initial Starting scene never means
that the workspace or applications are ready. Targets are 300 ms for attach
and 1 s for warm start; the regression comparison uses the recorded baseline.

The harness enables the native diagnostic log sink through `BEE_BOOT_LOG_DIR`
in its isolated child environment. Native phases use zap; runtime and Lua
phases use the existing event log with its original nanosecond timestamps.
Only known boot messages and phase fields enter the diagnostic sink. Logs
cover owner preparation/spawn/wait, native runtime load/start, registry loading,
application of the baseline, boot-listener readiness, migration checks by
owner, Hive supervisor and retained workspace progress, and client enrollment.
The shared `bee.persist` ledger emits each owner’s migration check once,
including workspace and client checks. Enrollment separates key
publication, authority overlay application and bootstrap publication. Its
supervisor readiness lookup selects exactly the node-local name table and
checks the current node, protected host and execution address. The supervisor
emits a `bee.launch` / `supervisor.ready` event after registering its local
name. Enrollment subscribes before its initial check and treats the event only
as a wakeup: every attempt checks the live local name again, writes the host
overlay, publishes the supervisor address, then lists clients locally. A failed
publication retains its bounded retry timer; successful idle enrollment does
not poll.
Work pending at the first frame remains explicitly listed in the result.

The native host implements `app.BootLogger`, so the pinned runtime writes its
own deployment selection, deployment verification, embedded Lua cache seeding,
artifact-cache seeding and runtime boot phases directly to the diagnostic sink.
Bee retains only host-owned preparation and lifecycle phases plus existing
runtime/Lua event observations. Mesh transport and native client presentation
remain inside the client-join interval.
