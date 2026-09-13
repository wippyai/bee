# Saved agent profiles

Installed in global Bee at production source `dc86273`. Saved-profile resolution,
admission and the picker/form workflow have native acceptance; remaining limits
are listed below.

A saved profile selects a reviewed launch definition and stores a title, scalar
options, MCP tool identifiers and appended instructions. The definition selects
the harness and isolation. The saved value cannot carry executables, credentials,
environment variables, permissions, endpoints or an instruction-builder function.
Dynamic context remains the runtime `ctx`; it is not a saved profile field.

`bee.harness.profiles:call` is the typed owner facade. Its request names an
operation (`get`, `list`, `put`, `remove`) and workspace identity. The native node
owns the records in the host-selected database, using the existing sync ledger.
The caller must have the corresponding workspace read/write action. A caller's
actor identity qualifies audit/retry receipts, not the durable profile owner, so
another authorized client can read the same workspace's preferences.

Mutations require the observed revision and an idempotency key. Removal writes a
tombstone. Lists use a bounded key page with an expected cursor for continuation;
a changed feed requires restarting the snapshot. Profile content is bounded and
decoded before any storage access. Host store grants alone do not authorize a
workspace operation. The production host binds profile read/write to the Agent app's inherited
workspace context. The facade supplies that context as policy metadata; the
request supplies only the checked resource. The Agent app cannot replace
function or process context. Explicit host policies may still authorize other
callers for separately selected workspace resources.

Six decoder cases pass. Three real-facade cases pass workspace authorization and
cross-workspace denial, reuse by different actors, mutation replay/conflict/removal
and snapshot invalidation. `make saved-profiles-check` additionally boots two real
runtime processes against the same disposable database: native node identity,
value/revision and the tombstone survive; a different authenticated reader sees
the saved value; historical receipt replay does not resurrect a removed profile.
The restart gate is included in `make check` and uses no desktop/driver closure.
The effort-option source (`dc86273`) passes all 836 unit cases. An earlier run hit the recurring
harness crash-recovery assertion (`clean child read evidence`); the passing rerun
does not establish its cause or a fix. Full repository acceptance of this source
is still pending.

Each workspace feed retains 128 change events and up to 1024 mutation receipts.
Receipt exhaustion refuses new edits instead of silently forgetting retry
history. A retention/compaction policy is not implemented.

Launch resolve, setup and admission now accept `saved_profile_id` and
`saved_profile_revision` alongside the workspace and definition. They read the
authorized profile and require its current revision and matching definition.
Admission also requires the displayed plan digest. The plan measures profile
identity/revision/content without returning instruction text to the picker.
Stale selection refuses before thread creation, grants or native execution.

`bee.driver:preferences` is the shared pure policy application used by launch
planning, the carrier and native configuration. `profile_options` in the host
launch policy maps editable option names to bounded lists of allowed scalar
values; driver control fields remain reserved. `profile_instructions: true`
permits appended profile guidance within the combined 4096-byte limit. Disabled
guidance is refused, never silently dropped. Selected MCP tools must be a subset
of the host list; hooks remain independent. Default host policies expose only low/medium/high effort choices; other editable options require explicit host policy.

Credentials retain the original host policy digest. Carrier/native requests carry
decoded preferences, and the resulting configuration and placement request are
measured separately. Native placement reapplies current host policy before a new
intent; an unadmitted option leaves no intent. Existing frozen placement delivery
continues to govern replay. The 42 focused cases pass shared preference bounds,
authorized profile resolution/admission, stale revision rejection, host digest
preservation and native pre-intent refusal, alongside existing launch tests.
Successful real-provider execution with edited options remains unverified.

Native Agent form/launch acceptance passes with a fixture harness. Saving preferences does not launch a process or create thread work.

No profile replication or cross-node human identity is claimed. Hive distribution
and governed registry overlays remain separate work.

The gateway source now admits hook reporting with an empty MCP tool set. Driver
configuration, carrier planning and native placement preserve the independent
hook selection; a binding with neither hooks nor tools is refused. The native
admission fixture proves the persisted binding has zero tools and its selected
hook. Gateway checks (13 cases) and focused policy/placement checks (11 cases)
pass. A real managed agent running with this selection is not yet verified.
This removes a dependency for profiles that restrict MCP without disabling
thread/title reporting. No production profile or global executable changed.

The managed-window envelope and checkpoint now preserve the selected profile ID
and revision alongside the measured plan. Cold recovery resubmits that selection
through the same admission checks; it cannot silently recover using default
preferences. Partial or invalid profile identities are refused. A changed or
removed saved profile therefore requires a fresh selection rather than silently
changing a recovered conversation's configuration. The picker carries this identity through setup and admission.

The picker requests a workspace-qualified saved-profile snapshot and carries its
selected ID/revision through both setup and admission. Saved choices contain no
instruction content. A failed saved-profile read leaves registry defaults usable
and shows the failure. The merge has a bounded page count and choice count;
tombstones and hidden definitions are not selectable.

The Agent picker now offers New and Edit (N/E shortcuts). New copies the selected
definition/profile into a new local profile identity. The form edits name,
appended instructions, host-allowed scalar options and MCP tool selection.
Tab/arrow keys change fields; Space/left/right change selections. Text accepts
typing/paste, Backspace and Ctrl+U clear. Ctrl+S saves; Escape cancels. Removal
requires confirmation. Default host harness policies permit appended guidance;
they still do not enable arbitrary editable options.

Form loading rechecks saved identity/revision against the authorized facade and
reads its allowed fields from the selected host policy. Saving and removal use
separate retry identities and expected revisions. Once submitted, retries keep
the same request values and competing save/remove operations are refused.
Successful saves return to the picker without launching. Form values and draft
instructions are transient until saved; closing the form discards the draft.

Thirty focused model, profile store, selection and recovery cases pass with the
form/editor source. Actual native keyboard form acceptance passes and the global build includes the form. Native launch with saved guidance passes using a fixture harness.

Follow-up source adds low/medium/high effort choices to the four default window
policies. Claude, Agy and Grok already translate effort to native flags; Codex
now emits a bounded model_reasoning_effort configuration override before any
subcommand or prompt delimiter. An omitted selection preserves harness defaults.
Strict lint and 23 focused profile/launch cases pass. These option defaults are
in the installed dc86273 binary.

The installed candidate additionally passes a real saved-profile fixture launch:
Agy receives the saved appended guidance in its private GEMINI.md and the scoped
gateway exposes the declared thread tools. This uses a fixture executable; no
authenticated provider model turn is claimed.

The effort candidate also passes native UI selection of high effort and an MCP
subset. The fixture checks the emitted Agy `--effort high` arguments and appended
guidance, then calls the actual authenticated gateway. Only `thread_read` and
`thread_wait` are listed and callable; a direct `thread_message` call receives
JSON-RPC invalid-params rejection and leaves the durable thread boundary unchanged.
This is real Bee admission and gateway I/O with a fixture executable, not a paid
provider turn. The checks remain outside production packs.

Continuation source now verifies the ended attempt, ownership and unambiguous
conversation observations before requesting any outstanding cleanup through
`bee.placement.native:cleanup`. It accepts only a completed cleanup reply for the
same attempt, owner, action and session. Refusal or uncertainty cannot admit a
replacement. This does not establish cold-window recovery: the terminal-identity
runtime requirement and interrupted-turn settlement remain separate gates.

The next native-window candidate captures the terminal's optional PID through
runtime PR #743, then records the Linux process group, start ticks and boot ID
using the existing identity reader before publishing `running`. Startup PID
polling yields within the admitted start budget, and supervision can report
`starting`. A close request during startup preserves `stopping` until completion
is observed; exhausted startup remains uncertain. These states authorize no
cleanup by themselves.

The real PTY fixture verifies persisted identity values, input/resize, observed
completion and ownership denial. A process-group fixture also proves live
cleanup refusal and cleanup after observed completion and independent group
absence. Full conversation recovery remains unproved; this candidate is not
installed globally yet. Retained
session directories remain separate from disposable attempt directories.
