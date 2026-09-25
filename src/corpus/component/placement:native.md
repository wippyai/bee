# bee.placement.native

Native placement: one admitted launch becomes one attempt, run as a native
child under a runner process this module owns. Receipts live in an owned
SQLite store opened through `bee.persist`; attempt homes and retained
session directories live under the host-owned `bee.placement.native:root`
volume, linked through the `target_root` requirement.

| Slice | Responsibility |
|---|---|
| `bee.placement.native` | `service`: the eight contract operations; `runner`: the per-attempt process that materializes the home, starts the child, records its identity, pumps output and input, signals and records exit; `store` and `migrations`: attempts and append-only evidence; `capability`: the measured cleanup capability of this runtime; `identity`: leader pid, start ticks and boot id; `homes`: derived directory keys under the root; `protocol`: runner, service and recipient messages; `resources`: linked references |

## Order of a start

1. `prepare` validates the request against this host's admitted roots,
   measures what the runtime can clean, refuses a launch that needs more
   than that, and records intent. Nothing external exists yet.
   A host policy selecting another placement is refused before the native
   capability probe or intent, even when a direct caller omits its placement
   hint. Calling the native operation does not override host selection.
   A request for `bee.environment:machine_home` is admitted only when the pinned host launch
   policy explicitly sets `allow_host_home: true`; profile metadata cannot grant
   that filesystem authority.
   Window login evidence is checked by existence in the selected provider
   home. An admitted file projection's source is also checked by metadata so
   a login about to be copied into a retained home does not produce a false
   warning. Neither check opens login bytes. An absent login adds an advisory
   `LOGIN_REQUIRED` notice to the prepare reply and does not stop the launch.
   A retained session home has one holder per owner/session pair: another
   attempt is refused until the predecessor is exited and its existing cleanup
   operation has proved the required scope gone and recorded `complete`.
   Repeating the same admitted idempotency key still returns its original
   attempt. This is an admission predicate in the existing placement
   transaction, not a home lock or a separate manager.
2. `start` spawns the runner under the placement scope and waits for its
   startup acknowledgment within the admitted start budget.
   `stop` before the runner claims startup atomically records exit and complete
   cleanup, releasing the retained session without touching its existing files.
   A delayed start cannot claim that stopped attempt; repeated stops return its
   recorded state. If startup wins the claim, normal runner stop and cleanup
   proof still apply. Thread receipts and gateway revocation retain their own
   owners; placement completion does not settle either operation.
3. Both structured and window runners atomically claim `intended` as `starting`
   before creating files. A duplicate runner refuses without replacing the
   recorded runner identity or materializing the attempt home. A launch that
   names both a retained session and its writable session
   home selects that session's derived `/home` before materializing provider,
   gateway, hook or trust configuration; the attempt home still owns attempt
   evidence and cleanup. Persisted host-generated configuration files in a
   retained home use atomic publication; login and provider conversation files
   remain separately owned. Argument-based configuration needs no replacement write. It resolves
   environment and working directory from the request and the admitted roots,
   starts the child (in its own process group when the runtime supports it),
   reads its identity, records `running`, and acknowledges.

## Environment ownership

Before each configuration publication, materialization rechecks that the attempt
is still `starting` and that the current process owns its runner identity. The
private filesystem root and the native provider's verified parent handles protect
the file boundary. Configuration cannot overlap the retained login marker, the
projected login file or provider initialization files. Existing immutable
`write_protected` callers still permit only byte-identical replay.

Publication is per file. A later failure does not roll back earlier files, and
startup refuses if any file fails. If the native error reports that rename
succeeded but directory sync failed, placement records `configuration.uncertain`
and keeps execution uncertain; a successor cannot take that retained session.
The predecessor checkpoint remains unchanged. This outcome requires inspection;
there is no automatic retry or replay of the user's prompt.

Native placement owns `HOME`, selected from its attempt or retained session home.
An admitted gateway owns its tool and hook token destinations. `prepare` refuses
literal or referenced environment values that collide with those names, and
refuses a shared tool/hook destination, before recording intent. Materialization
checks those assignments again for a retained request.

Credential projections cannot overwrite a policy value, another projection, the
native home or a gateway destination. Such a conflict ends materialization before
the child starts. Error replies and evidence name the destination and projection;
they contain no credential bytes. Policies supply nonsecret configuration while
the credential broker supplies secrets; precedence is not used to hide conflicts.

Nested configuration paths create each missing parent in order. Every existing
ancestor must belong to the current materialization's created-parent set;
retained byte-identical file replay remains unchanged. This permits Agy's
`.agents/mcp_config.json` in a retained customization root without adopting
or changing the user's global configuration directories.

## Retained provider login destinations

`homes.retain_login` receives broker file projections during runtime materialization
only after a launch selects its retained session home. It accepts bounded opaque bytes and
a frozen host-selected relative target declared by the harness component.
Codex declares `.codex/auth.json`, Claude `.claude/.credentials.json`, and Agy
`.gemini/antigravity-cli/antigravity-oauth-token`. Claude's declaration also initializes `.claude.json` with only
`hasCompletedOnboarding: true`: the real CLI otherwise asks for a login method
despite recognizing the imported subscription. This does not trust any project,
import machine settings or change later harness-owned preferences. An absent
optional login does not initialize onboarding. Existing retained homes are not
rewritten. Nested parent creation records every directory it creates, so later
immutable driver configuration can share those directories. Existing parents
are refused unless the current materialization created them; login formats
cannot overwrite the retained identity marker.

The first seed records a separate nonsecret
provider/definition-id/definition-revision identity only after the opaque file
has been completely written. A matching resume leaves the login file untouched,
so bytes refreshed by the harness persist. A changed provider, definition or
revision, or either half of an interrupted seed, refuses reuse. It neither emits
evidence nor treats opaque bytes as immutable configuration. The native fixture
checks the placement root's actual `0700` mode rather than registry metadata.
The helper reads the root's actual numeric `fs.FileInfo.mode` and refuses group
or other access; it does not infer privacy from the registry declaration. The
pinned `fs` write contract reports an error for a short write, so a successful
write plus successful close is the ready-marker precondition. It has no fsync
operation: ready-marker ordering refuses interrupted process writes, but is not
a machine-power-loss durability claim.

An optional source can seed no bytes while recording the same source binding
with `optional=true`. A matching retained home then preserves either an absent
file or a file created by interactive sign-in; later machine credentials never
replace either choice. Required sources still refuse a missing login file.
Changing optional policy also changes the binding and refuses reuse. Empty
provided bytes remain an error. Native materialization requires explicit `present` and `optional` flags from
the broker; absent bytes are accepted only for an optional absent reply. This
records an unseeded home without placing file credentials in the environment.
First-use setup preserves the host-selected optional policy and refuses a
conflicting existing definition. Default Claude, Codex and Agy window profiles
use the explicitly authorized host HOME and select no login-file projection.
Agy places Bee-generated files in its retained session customization root.
Private structured profiles may still select declared credential sources.
Source-free acceptance covers present and absent global login and exclusion of
Bee-generated files from global configuration trees, using fixture CLIs. Real
authenticated provider turns remain verified separately per driver.

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

A stop accepted during materialization fences the asynchronous credential reply
before login seeding. If no child was created, the same runner commits its exit
and `child.not_started` evidence together. Cleanup can use that proof only when
all native identity fields are absent. Missing identity without this evidence,
partial identity, a foreign runner or uncertain execution does not authorize
cleanup. Retained session homes remain available for a subsequent admitted attempt.

## Resource modes

The host selects the mode in `bee:placement_resource_mode`; a
request cannot. The shipped default is `granted`, so managed Agent resources
are validated through their authority on use. In `host_configured` mode
`bee:placement_admitted_roots`
lists the `fs.directory` roots a launch may name with the widest access the
host allows, `prepare` checks the caller, the root, the subpath and the
access mode against that list, and a request's `grant_ref` is correlation
data only. In `granted` mode every `grant_ref` is a grant id resolved
through `bee.resources.binding:resolve` for the owner this placement admitted, with
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
through `bee.credentials.binding:check` for the owner it admitted with the attempt
as scope. Environment projections materialize right before the child starts
at the provider's fixed environment destination. An absent optional environment
projection is validated and omitted; placement never creates an empty variable.
A populated projection must explicitly report `present: true`, its optional flag
and UTF-8 encoding before placement adds it to the exact child environment. A
file projection requires the selected retained session home, validates its frozen declared login
destination and nonsecret definition identity, then writes its opaque bytes
before immutable driver configuration. One file projection may select a
retained home; matching later resumes preserve provider-refreshed bytes.
Evidence carries only the projection id and outcome, and the stored request
never carries a value. `start` and `reconcile` re-check the bindings like
resource grants.

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
leader is identified alive by pid, start stamp and boot identity; otherwise
the attempt becomes `uncertain`. Linux reads the start stamp in clock ticks
from `/proc` and the boot id from the kernel; macOS reads the start second
from the process table and `kern.bootsessionuuid`. Both read the process
group with `ps`. A group signal succeeds only when the OS command
exits with status zero. Command refusal leaves stop unproven and records
`stop.unproven`, rather than claiming `signal.group` evidence.
`reconcile` proves absence the same way and
keeps uncertainty where identity is missing. `cleanup` removes the home
only from `exited`; a cleanup whose scope is not proven gone records
`cleanup.refused` with its reason before it answers `CONFLICT`.

Configured launches must carry the digest of their host-selected provider and
gateway inputs. Placement reconstructs those inputs from its pinned policy,
activation and binding, refusing omissions or changes before storing intent.
Caller-supplied delivery is rejected. For a new intent the activated driver
renders bounded argument literals and protected files under an empty callee
scope, using the owner-derived home path. The existing intent stores that
validated output; identical retries reuse it without re-rendering. Both native
execution transports use the same materialization component. Drivers own their
formats, including Claude's inline settings and Codex's files; placement owns
credential delivery, protected writes and session-home exclusion.

Reading an intent decodes the stored request and its private delivery again,
including file digests, paths and argument bounds, before creating a home or
starting a child. Malformed stored content is a storage failure. Its retry
digest still identifies the original caller request; resolved resource grants
in the stored request do not redefine that identity.

## Managed terminal supervision

The process-local window owns its PTY and answers the existing placement status
probe without consuming the application's terminal completion channel. The
periodic sweep therefore rechecks grants without marking a live Agent uncertain
merely because a PTY exposes no host execution identity. This reply proves live
supervision, not post-crash execution absence or cleanup.

Stop notifications are acted on only after the placement store records `stopping`
for the exact attempt, owner and runner. An arbitrary process message cannot
stop the window. The listener is installed before publishing `running`; publication compares the
recorded state with `starting`, so a concurrent stop cannot be overwritten. The
window retires its listener when finalization commits.
Native PTY acceptance proves live reconciliation, raw-stop denial, admitted stop,
input, resize, finalization and duplicate/foreign-owner refusal. A native Agent
fixture also keeps its MCP binding live across the real 30-second sweep.
