# bee.placement.native

Native placement: one admitted launch becomes one attempt, run as a native
child under a runner process this module owns. Receipts live in an owned
SQLite store in `bee:db` (`bee.persist`); attempt homes and retained session
directories live under `bee.placement.native.env:root` (`BEE_PLACEMENT_ROOT`,
default `.wippy/placement`, mode `0700`), which the `root_ref` entry links.
The other host references are the `bee.resource_ref` entries `runner_host_ref`
(`bee:workers`), `executor_ref`, `host_files_ref`, `admitted_roots_ref`,
`resource_mode_ref` and `workdir_preparers_ref`; replacing one's target
selects a different resource.

| Namespace | Responsibility |
|---|---|
| `bee.placement.native` | `protocol`: the runner/service wire protocol |
| `bee.placement.native.binding` | The contract binding, one function per contract method plus `stop_revoked`, and `process_backend` |
| `bee.placement.native.service` | `service` (operations), `runner`, `startup` supervision, `window`, `materialization`, `homes`, `identity`, `capability`, `executable`, `workdir_preparers`, `writable_roots_adapter`, `provider_projection`, `sweeper_service` |
| `bee.placement.native.persist` | `store`: attempts and append-only evidence |
| `bee.placement.native.migrations` | Immutable schema migrations (`attempts`, `complete`) |
| `bee.placement.native.env` | Root, executor, host files, admitted roots, resource mode and preparer entries; `resources` and `configuration` libraries |
| `bee.placement.native.security` | Permission policies (`placement_store_policy`, `placement_exec_policy`, `placement_service_policy`, `placement_sweeper_policy`, `placement_runner_policy`) |

## Order of a start

1. `prepare` validates the request against this host's admitted roots,
   measures what the runtime can clean, refuses a launch that needs more
   than that, and records intent. Nothing external exists yet.
   A host policy selecting another placement is refused before the native
   capability probe or intent, even when a direct caller omits its placement
   hint. Calling the native operation does not override host selection.
   A request for `bee.env:machine_home` is admitted only when the pinned host launch
   policy explicitly sets `allow_host_home: true`; profile metadata cannot grant
   that filesystem authority.
   Window login evidence is checked by existence in the selected provider
   home. An admitted file projection's source is also checked by metadata so
   a login about to be copied into a private or retained home does not produce a false
   warning. Neither check opens login bytes. An absent login adds an advisory
   `LOGIN_REQUIRED` notice to the prepare reply and does not stop the launch.
   A retained session home has one holder per owner/session pair: another
   attempt is refused until the predecessor is exited and its existing cleanup
   operation has proved the required scope gone and recorded `complete`.
   Repeating the same admitted idempotency key still returns its original
   attempt. This is an admission predicate in the existing placement
   transaction, not a home lock or a separate manager.
2. `start` returns the durable `starting` attempt once its runner is spawned
   and monitored by an attempt supervisor. The caller does not wait for child
   startup. The supervisor consumes authenticated acknowledgements and runner
   exits for the runner's lifetime. The runner records `running` after startup
   and identity resolution, or `start_failed` with the exact refusal cause.
   Exit before acknowledgement records the runner's exit reason as a startup
   failure. Recipient notifications use `bee.placement.started` as a hint to
   read the authenticated owner status; the store reads attempt state and its
   failure and cancellation evidence in one SQL snapshot.
   Slow startup stays `starting` until acknowledgement, refusal, observed exit
   or an explicit stop. Each executor operation keeps its own runtime bound.
   `stop` before the runner claims startup atomically records exit and complete
   cleanup, releasing the retained session without touching its existing files.
   A delayed start cannot claim that stopped attempt; repeated stops return its
   recorded state. If startup wins the claim, normal runner stop and cleanup
   proof still apply. Thread receipts and gateway revocation retain their own
   owners; placement completion does not settle either operation.
3. The structured supervisor claims `intended` as `starting`; window runners claim it directly
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

## Workdir preparers and writable roots

Placement exposes a generic `bee.placement:workdir_preparer` extension point discovered
from the registry and authorized by the host's `bee.placement_workdir_preparers` entry
`bee.placement.native.env:workdir_preparers` (registry metadata alone never
authorizes), which lists `bee.git.worktree.binding:binding`. Each binding implements read-only `plan`, idempotent
`setup`, and idempotent `cleanup`. Placement persists plan state and the selected
method targets before calling setup, including for preparers without state. The
plan record lives whole in `bee_placement_preparer_states` (at most 64 KiB; a larger
state refuses the launch before setup) and one `workdir_preparer.state` evidence row
names the binding. The preparer methods require the runner's setup action or the
service's cleanup action, so a caller without placement's policies is denied.
Write roots handed to preparers are each grant's physical `root/subpath`; Git
metadata outside a granted subpath needs its own grant.
Setup declares the option names it handles; unhandled requested options refuse the launch.
Changed bindings cannot replace a recorded plan during setup replay.
Cleanup runs on proven attempt ends and the supervisor sweeps outstanding plans.
Failures do not prevent other planned preparers from receiving cleanup. It may contribute extra writable roots inside already
write-granted roots, update the working directory (such as creating a dedicated Git worktree),
and preserve planned ownership state between setup and cleanup. Failures are recorded as placement evidence
(`workdir_preparer.failed`).

The per-CLI argument rendering stays owned by placement's `writable_roots_adapter`.
When extra writable roots are contributed and remain inside host-admitted write roots,
placement renders the driver profile's `git_writable_roots_adapter`: Codex receives
`sandbox_workspace_write.writable_roots`; Claude Code and Agy receive `--add-dir` for each path.
Placement resolves physical directories (including symlinks and parent components)
and refuses malformed roots or roots and changed workdirs outside write grants.
Cleanup preserves uncertainty when process absence cannot be proven. It records
retention, checks evidence writes, and surfaces preparer failures even if home
removal also fails.
A read-only workdir, a profile without the matching edit-capable CLI mode, or a launch
without contributed writable roots receives no extra arguments.

Native placement owns `HOME`, selected from its attempt or retained session home.
For a driver's private provider home, placement also sets only its declared
provider-home variables (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `GROK_HOME`, or
OpenCode's XDG roots) below that same private home. An admitted gateway owns its
tool and hook token destinations. `prepare` refuses literal or referenced
environment values that collide with those names, and refuses a shared
tool/hook destination, before recording intent. Materialization checks those
assignments again for a retained request.

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

## Input closure

`close_stdin` authenticates the attempt owner before checking its state. A child
that has already exited returns its recorded attempt, `closed: false` and the
exit reason; it creates no `stdin.closed` evidence. Callers can finish draining
the output under that attempt's observed exit instead of reporting a closure
failure solely because the short-lived child won the race.

## Provider login homes

Private attempt homes are created empty. A private `provider_home` declaration
selects the provider's machine-home source paths, private destinations, runtime
home variables and whether its login can be returned after exit. The declaration's
file list may be empty for an account-free CLI; its private home receives no
ambient file projections. The credential broker supplies bounded bytes only
for source paths admitted by the host;
placement compares every returned login and setup path with the driver
declaration before creating files. It never scans the source home or copies
unlisted files. Optional absent logins leave the token destination absent.
An admitted launch with a SessionRef and writable home resource uses that
Session’s retained home, including private provider homes. Login, configuration
and conversation state remain there across turns. Launches without a selected
session home use separate attempt homes.

`homes.project_attempt_login` writes only the broker's primary login file and
its admitted setup initializers into a newly created attempt home. Claude's
format also initializes `.claude.json` with only `hasCompletedOnboarding: true`
when login bytes are present; this lets Claude Code recognize the imported
subscription without importing unrelated home state. Setup configuration is
copied as admitted, or created empty only when its host declaration marks it as
a composition base. Bee's generated provider configuration is then composed by
the selected driver.

The CLI may refresh its own login file while it runs. The pinned runtime has
no Lua filesystem operation that opens a regular file while refusing symlinks
in every path component. The runner therefore refuses provider login
write-back with `provider login write-back requires runtime no-follow fs` after
the child exits. It leaves the worker file unchanged and never truncates or
rewrites it to validate the path. Host-to-private-home projection remains
available because the credential broker reads only the host-declared source
files before the worker starts.

Configuration and state files are never returned. Evidence records status and
projection identity only; it never contains login bytes.

Retained homes keep their existing identity marker and seed rules. The first
seed records provider, definition ID and revision only after the login file is
completely written. A matching resume leaves the login file untouched, so
provider-refreshed bytes persist. Changed identity or an interrupted seed
refuses reuse. Existing parents are refused unless the current materialization
created them; login formats cannot overwrite the retained identity marker.

An optional source may seed no login bytes. Retained homes preserve either an
absent file or one created by interactive sign-in; later machine credentials
never replace either choice. Required sources refuse a missing login. Changing
the optional policy changes the retained binding and refuses reuse. Empty
provided login bytes remain an error. Default provider windows use the
explicitly authorized host HOME and select no login projection, except Grok,
whose private window projects `grok_login` into its selected retained session
home. Private batch launches without a retained home selection project their
declared files into attempt homes.

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
`close_stdin` waits for the exact runner acknowledgement or monitored runner
EXIT, draining queued acknowledgements before reporting their absence. Send,
monitor, cancellation and runner failures retain their causes.
EOF stops are separate messages from chunks, and exit is separate from EOF.
The runner retains the two EOF markers even after acknowledgement, replays
acknowledged markers to a newer attachment generation, and excludes them from
unacknowledged output counts and retention obligations.

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
Overlapping cleanup calls treat a home entry already removed by the other
caller as gone; a path still present after a filesystem error stays uncertain.

A stop accepted during materialization fences the asynchronous credential reply
before login seeding. If no child was created, the same runner commits its exit
and `child.not_started` evidence together. Cleanup can use that proof only when
all native identity fields are absent. Missing identity without this evidence,
partial identity, a foreign runner or uncertain execution does not authorize
cleanup. Retained session homes remain available for a subsequent admitted attempt.

## Resource modes

The host selects the mode in `bee.placement.native.env:placement_resource_mode`; a
request cannot. The shipped default is `granted`, so managed Agent resources
are validated through their authority on use. In `host_configured` mode
`bee.placement.native.env:placement_admitted_roots`
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
`revocation_enforcement: stop_on_reconcile` and `credential_broker: true`.

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
inside a running child cannot be scrubbed; enforcement is the stop. Startup
refusals retain the exact operation cause in `child.start_failed`; grant and
credential enforcement evidence names the refused authorization without
recording credential values.

## Attachment fence

`attach` records the new generation and, when a runner lives, sends it the
generation and waits for the runner's acknowledgment before returning; a
runner that does not answer within the fence timeout leaves the attempt
`uncertain`. After the fence the runner accepts input and acknowledgments
from the new recipient only, and answers a refused write with the sender's
own generation.

## Uncertainty

Startup has no caller deadline. Timestamped evidence records admission,
monitor installation, runner materialization, executor return, identity
resolution and acknowledgement delivery. Acknowledgements queued before EXIT
are drained before the supervisor concludes startup failed. A stopped attempt
cannot transition back to `running`; late acknowledgements remain evidence.
A stop before child creation projects `start_cancelled` from the existing stop
and no-child evidence. Consumers settle cancellation directly, without an exit
code or exit source. Reconciliation never guesses a startup result from runner
absence while its monitor is recording the outcome.

Signal evidence is not exit evidence; the runner records exit only from
`wait`. Without a live runner, `stop` signals the group only after the
leader is identified alive by pid, start stamp and boot identity; otherwise
the attempt becomes `uncertain`. Linux reads the start stamp in clock ticks
from `/proc` and the boot id from the kernel; macOS reads the start second
from the process table and `kern.bootsessionuuid`. Both read the process
group with `ps`. A group signal succeeds only when the OS command
exits with status zero. Command refusal leaves stop unproven and records
`stop.unproven`, rather than claiming `signal.group` evidence.

Reconciliation treats a starting attempt without an execution identity as
supervised while its runner process is present on a host: the runner answers
status probes only once its child exists. A starting attempt whose runner is
absent becomes `uncertain`.
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

The shared `process_backend` value lets Docker reuse this materialization,
runner and window lifecycle while supplying its executor, physical mounts,
container identity and cleanup proof. Native stream handles are acquired before
start; Docker stream handles are acquired after start. EOF-based Docker turns
read initial input from a protected file in the admitted private home, so a
container's attached stdin lifetime cannot keep a one-turn provider waiting.

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

The window registers the same private per-attempt control token as the streamed runner.
Stop notifications require that token and are acted on only after the placement store records `stopping`
for the exact attempt, owner and runner. An arbitrary process message cannot
stop the window. The listener is installed before publishing `running`; publication compares the
recorded state with `starting`, so a concurrent stop cannot be overwritten. The
window retires its listener when finalization commits.

Structured turns with a SessionRef and an admitted writable session home retain
the driver-selected provider state across attempt cleanup. Ephemeral turns keep
their attempt-local private home.

Private provider configuration uses the shared provider projection scanner. It bounds nesting and resolves `{file:...}` references
only to driver-declared files materialized by the credential broker. Both
absolute host-home paths and `~/` references become paths under the private
home. Undeclared, absent, traversing or unresolved dependencies refuse before
child creation; refusal evidence contains no configuration values. Native
descriptive text containing a home path remains text. Docker projection retains
its stricter host-command and path checks and declared portable configuration.

After an independently observed child exit, pipe draining has a bounded read
budget. Time spent with reads paused at the output spool limit does not consume
that budget. After child exit, the retention deadline bounds each continuous wait at the
spool limit; acknowledged progress that resumes reads ends that wait. Once both
streams end, one retention deadline bounds the remaining unacknowledged output. Drain expiration records forced
truncation only after queued pipe chunks and EOFs have been consumed; retention
expiration records output loss rather than consumption. Selecting an expired
drain bound cannot discard pipe events already available to the runner.

Native preparation decodes host prepare options through the same driver preferences
decoder as the carrier planner before comparing the configuration digest. Empty
registry maps and absent options therefore select the same default options.
