# bee.placement.native

Native placement: one admitted launch becomes one attempt, run as a native
child under a runner process this module owns. Receipts live in an owned
SQLite store opened through `bee.persist`; attempt homes and retained
session directories live under a placement-owned root.

| Slice | Responsibility |
|---|---|
| `bee.placement.native` | `service`: the eight contract operations; `runner`: the per-attempt process that materializes the home, starts the child, records its identity, pumps output and input, signals and records exit; `store` and `migrations`: attempts and append-only evidence; `capability`: the measured cleanup capability of this runtime; `identity`: leader pid, start ticks and boot id; `homes`: derived directory keys under the root; `protocol`: runner, service and recipient messages; `resources`: linked references |

## Order of a start

1. `prepare` validates the request against this host's admitted roots,
   measures what the runtime can clean, refuses a launch that needs more
   than that, and records intent. Nothing external exists yet.
2. `start` spawns the runner under the placement scope and waits for its
   startup acknowledgment within the admitted start budget.
3. The runner records `starting` and creates the attempt home under a derived
   key. A launch that names both a retained session and its writable session
   home selects that session's derived `/home` before materializing provider,
   gateway, hook or trust configuration; the attempt home still owns attempt
   evidence and cleanup. A later attempt may reuse only byte-identical
   host-approved configuration already in that retained home. It resolves
   environment and working directory from the request and the admitted roots,
   starts the child (in its own process group when the runtime supports it),
   reads its identity, records `running`, and acknowledges.

## Capability

`capability.measure` starts a probe child with `process_group` and reads its
group id back. A runtime whose handle carries no pid reports
`direct_process`; a probe that leads its own group reports `process_group`.
No runtime here reports `contained_tree`: a descendant that starts its own
session escapes a process group. The measured value is recorded on every
attempt and returned by `capabilities`.

## Streams

Output leaves the runner as chunks with one sequence per attempt, addressed
to the bound recipient under the current attachment generation. The runner
keeps unacknowledged chunks up to a spool bound; beyond it the pump blocks
and the child blocks on its pipe. Input arrives with a write id and the
generation; a repeated write id is acknowledged without a second write.
EOF stops are separate messages from chunks, and exit is separate from EOF.

## Exit observation

A runtime whose handle offers `done()` lets the runner learn the exit
independently of the pipes: `exit_observation: independent`. Without it the
runner can only call `wait()` after both streams end, because `wait()`
consumes the handle that signalling and input need: `eof_gated`. A child
that exits while a descendant holds stdout is then observed late, and a
child that closes its pipes while running would be lost to `wait()`.
Managed harness launches require `independent`; `prepare` refuses them on
an `eof_gated` runtime. Only bounded fixture and simple-command launches
declare `required_exit_observation: eof_gated`.

## Cleanup scope

`exited` says the direct process ended, observed by the runner or proven
absent by identity. It does not say its group or descendants ended.
`cleanup` removes the home only when the required scope is proven gone:
`direct_process` by the observed exit or proven leader absence,
`process_group` when no member of the recorded group answers a signal
probe, `contained_tree` never on this runtime.

## Resource modes

The host selects the mode in `bee.placement.native:resource_mode`; a
request cannot. In `host_configured` mode `bee.placement.native:admitted_roots`
lists the `fs.directory` roots a launch may name with the widest access the
host allows, `prepare` checks the caller, the root, the subpath and the
access mode against that list, and a request's `grant_ref` is correlation
data only. In `granted` mode every `grant_ref` is a grant id resolved
through `bee.resources:resolve` for the owner this placement admitted, with
the attempt as scope; the authority's root and subpath replace the caller's,
the resolved grants are recorded with the attempt, `start` resolves them
again before spawning the runner (`grant.refused` evidence and the
authority's code otherwise), and `reconcile` resolves them for a live
attempt and stops it cooperatively when one no longer holds
(`grant.revoked` evidence; enforcement is pending until the exit is
proven). `capabilities` reports the mode, `delegated_resource_grants`,
`revocation_enforcement: stop_on_reconcile` and `credential_broker: false`.

## Input uncertainty

The runner deduplicates writes by write id while it lives. A runner lost
after bytes were written and before the acknowledgment was recorded leaves
those writes uncertain; the recipient must not write them again on its own.

## Credential projections

A launch names credential projection ids. `prepare` checks each binding
through `bee.credentials:check` for the owner it admitted with the attempt
as scope; the runner materializes each through `bee.credentials:materialize`
right before the child starts and places the value in the child's
environment at the provider's fixed destination; evidence carries only the
projection id and the outcome, and the stored request never carries a
value. `start` and `reconcile` re-check the bindings like resource grants.

## Supervision

`sweeper_service` (registered as `bee.placement.sweeper`) reconciles up to
`sweep_bound` live attempts every scheduling delay through the
owner-independent `reconcile_attempt` and `stop_attempt`, so a revoked grant
or projection is stopped within a bound rather than at the next owner call.
`capabilities` reports `revocation_enforcement` with the scheduling delay,
the reconcile timeout, the per-attempt stop grace and the sweep bound as
separate figures, because the sweep interval alone is not a stop deadline.
Evidence names what failed: `grant.revoked` or `credential.revoked`,
`grant.refused` or `credential.refused`. An environment value already
inside a running child cannot be scrubbed; enforcement is the stop. Native
executor error text is never recorded; evidence carries fixed phrases.

## Attachment fence

`attach` records the new generation and, when a runner lives, sends it the
generation and waits for the runner's acknowledgment before returning; a
runner that does not answer within the fence timeout leaves the attempt
`uncertain`. After the fence the runner accepts input and acknowledgments
from the new recipient only, and answers a refused write with the sender's
own generation.

## Uncertainty

Signal evidence is not exit evidence; the runner records exit only from
`wait`. Without a live runner, `stop` signals the group only after the
leader is identified alive by pid, start ticks and boot id; otherwise the
attempt becomes `uncertain`. `reconcile` proves absence the same way and
keeps uncertainty where identity is missing. `cleanup` removes the home
only from `exited`.

Provider configuration is mandatory when the selected host launch policy names
`provider_ref`. Omitting it is denied before recording an attempt intent;
providing a file is admitted only when its provider identity, safe relative
home path, revision, digest and content match the activated driver's
host-rendered configuration. Placement pins the policy, provider, activation
and binding together, then calls `configure` with copied records under an empty
callee scope. Policies without a provider require that same binding to return
no file, so a request's binding reference never selects a renderer. Gateway
sections in a provider file are currently limited to Codex; placement denies a
configured generic driver combined with gateway tools. The placement regression
proves that an omitted required configuration creates no attempt row.
