# Saved agent profiles

Source work in progress; not installed or exposed in the Agent picker yet.

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
workspace operation. The production host currently grants no profile read/write
permissions to the picker.

Six decoder cases pass. Three real-facade cases pass workspace authorization and
cross-workspace denial, reuse by different actors, mutation replay/conflict/removal
and snapshot invalidation. `make saved-profiles-check` additionally boots two real
runtime processes against the same disposable database: native node identity,
value/revision and the tombstone survive; a different authenticated reader sees
the saved value; historical receipt replay does not resurrect a removed profile.
The restart gate is included in `make check` and uses no desktop/driver closure.
The current full unit run passes all 813 cases. An earlier run hit the recurring
harness crash-recovery assertion (`clean child read evidence`); the passing rerun
does not establish its cause or a fix. Full repository acceptance of this source
is still pending.

Each workspace feed retains 128 change events and up to 1024 mutation receipts.
Receipt exhaustion refuses new edits instead of silently forgetting retry
history. A retention/compaction policy is not implemented.

Next integration must resolve the selected definition and current host policy
again at launch, validate user options under that policy, restrict MCP tools to
its authorized set and bind profile identity/revision/content into the launch
plan. A stale selection must fail before credential reads, gateway grants, thread
creation or native execution. Only then should the picker/editor use this facade.
Saving preferences must never launch a process as a side effect.

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
