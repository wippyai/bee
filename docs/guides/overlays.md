# Distributed overlay delivery

Bee distributes immutable application artifacts. Distribution makes an exact
version available on another Bee; it does not install it, select it, activate
it, or grant authority there. Governance owns authoring and activation, Hive
owns authenticated transfer, and Approvals owns the human decision.

## Delivery model

An author creates a declarative application in an overlay, freezes it and has
its exact content reviewed and applied locally. Publication then appends a
source-qualified immutable descriptor to the delivery feed. The descriptor and
artifact contain no destination workspace, approval, host policy, registry
writer, filesystem root, process, mount or credential.

A destination stores the received artifact under its source, feed and version
identity. It verifies every bounded chunk, total length and final digest before
marking that replica `available`. A source withdrawal stops future delivery; it
does not remove a version a destination already holds or uses.

Each destination independently:

1. stages an available replica by its complete source/feed/version identity;
2. resolves and preflights it against its own registry and host policy;
3. reviews the exact candidate and its changes;
4. selects and prepares the version;
5. obtains a local approval; and
6. applies the approved intent through its owner-local overlay generation.

Receipt of a later version never changes the selected or active version. A
destination can stage the same source version independently from other
destinations. Its plan, selection, approval, activation receipt and overlay do
not leave that destination.

## Review and activation

Overlays shows the destination-local plan. It displays the measured artifact,
preflight report and report digest, diagnostics and remedies, pending migrations,
and entries added, changed or removed against the captured composed base. It
also shows selection, approval and activation state. A malformed report,
blocked preflight or stale plan cannot be selected or prepared.

The activation owner re-resolves and re-preflights immediately before applying.
It applies only the exact reviewed definitions through a generation-fenced
overlay API and records the observed outcome. A generation conflict or a base
that changes during the operation leaves an explicit uncertain or refused
result; the owner does not infer success or write registry history. Restart
recovery restores only the previously authorized desired intent.

Durable registry publication is a different operation. Overlay activation does
not become a registry-history write, and a registry publication guard must not
be simulated with a Lua pre-read.

## Agent path

A managed agent uses the bounded `overlay` MCP tool to read the authoring guide
and create, list, read, put, append, remove and freeze its own overlay. The agent does
not receive direct overlay-store access. `workspace_id` is not an authoring
alias; public authoring calls use `overlay_id`.
`list` without `overlay_id` returns the caller's own overlays and revisions;
with an ID it returns that overlay's file manifest.

An MCP `put` writes up to 65,536 decoded bytes. For a larger `entries.json`,
put its first chunk, then call `append` for each remaining chunk. Each append
supplies `expected_revision`, a new `idempotency_key` and the current byte
`offset`. The owner computes the assembled SHA-256 digest. If the caller
already knows it, optional `result_digest` asserts that value; a mismatch
changes nothing. One file may contain up to 4 MiB; an overlay may contain up to 16 MiB.
`list` returns file byte counts and digests; `read` returns a base64 window of
up to 16,384 bytes with `offset`, `chunk_bytes` and `eof`. Page with `offset`
and `limit` to verify a file before freezing.

The `delivery` tool can request delivery of a frozen artifact and read a
staged version's review, selection and activation status. Its destination is
the agent's own workspace unless it names that workspace explicitly. The `publish` tool
can publish only an exact locally reviewed and applied version, and a host may
place it behind an approved access trait. Neither tool can approve, activate or
write an overlay. People review in Overlays and decide in Approvals; the
activation owner performs the apply.

Delivery requests retain `workspace_id` for the destination runtime target and
`source_overlay_id` for the authoring identity. Internal services may use other
storage fields, but those are not public authoring vocabulary.

## Workspace applications

A fresh install delivers an application a workspace's own agent authors to
that workspace without host configuration, and still only after the person
approves it. The shipped `bee:governance_publication_profiles` sets
`workspace_applications: true`, and the shipped
`bee:governance_activation_profiles` carries a `workspace_applications` rule:
the approval policy (`workspace-application-delivery`, decided in Approvals by
the person, as `bee:approver_policies` ships it), the admitted entry kinds and
native modules, and the admission policies and thread access of the one
application entry.

The rule applies only to an overlay this node authored whose name is lowercase
letters, digits and underscores starting with a letter. Overlay `todo` gets
component and namespace `app.todo`, the application entry `app.todo:app` under
the ordinary application boundary, and the private overlay owner
`bee.governance.workspace_applications:<workspace_id>.todo`. Nothing under the
rule starts itself: an entry that declares `lifecycle.auto_start` is refused at
preflight with `AUTO_START_DENIED`, so the application runs only while the
broker has it open. An explicit profile row for the same source takes
precedence; it admits auto start unless its `allow.auto_start` is `false`. A source the rule does not
cover is refused with the rule and the profile entries a host adds.

The shipped workspace application profile also admits `ns.requirement` entries
for capability requests. A request declares `meta.value_kind: security.policy`,
`meta.capability`, bounded `meta.parameters`, and a printable `meta.reason`. Its
single target must be its own `bee.application` process entry at
`.security.policies +=`. The destination resolver checks the request against
the host-owned `bee:capability_catalog`, preserves the normalized parameters,
reason, target, and catalog/template revisions in the measured candidate, and
includes the catalog definition in the candidate's external-base digest. The
request grants no policy. Preflight refuses app-shipped `security.actor` and
`security.groups` on every entry with `SECURITY_DENIED`.

The catalog currently describes `workspace.files.read`, `app.database`,
`threads.read`, `threads.message`, `agents.launch`, `contract.call`, `http.api`
and `hive.expose`. Its decoder bounds relative subpaths, lists, identities and
HTTPS origins; it also carries a never-list for execution, environment and
credential access, registry and scope management, approval decisions, core
databases, and auto start. Pure helpers expand templates into proposed
operation/resource/scope values, compare two resolved grant sets semantically,
and render host-authored permission text with combined read-to-egress lines.
For workspace application delivery, the host resolves these values before
approval and shows the full set, changes from the installed grant, and any
combined data flows in Approvals. Only `threads.read` with `scope: owned` has
an installable policy in this slice; unsupported requests fail resolution.

On approval, one registry overlay transaction installs host-owned policies in
`bee.governance.grants`, fills the requirement defaults, and records the grant
set, digest, approval ID, and revision. The workspace application rule derives
its policy allowance, application binding and thread access from that live
record. A later version still receives artifact measurement and preflight. If
its resolved set is contained in the installed grant, it reuses that approval
and installs only the requested subset. Widening asks the person to approve
the delta; refusal leaves the installed version and grant intact.

The shipped `workspace_applications` ceiling admits only `process.lua` and
`library.lua` entries. Native imports are limited to `tty`, `process`,
`channel`, `json`, `time`, `uuid`, `base64` and `hash`. The application binding
gets `bee:ordinary_app_subsystem_boundary` and `thread_access: none`.
`db.sql.sqlite`, `store.memory`, `sql` and `store` are outside this ceiling.
These are ceilings, not a grant to launch any agent definition: launch remains
subject to the host's separate definition and application policies. Although
the catalog describes app database, launch and thread requests, this rule does
not provision an app database or install requested launch or thread grants.

### Can a workspace application get its own database?

No app-owned SQL or KV database is provisioned for a workspace application.
The implemented durable state is an opt-in application checkpoint of at most
65,536 bytes. It survives workspace restart for an automatic instance; closing
the live view removes its resume record, so it is not a durable app database.

A person reviews the staged plan in Start › Tools › Overlays, selects and
prepares it there, approves the request in Start › Tools › Approvals, and lets
Overlays step the activation owner until it settles; the application then
appears in the Start menu. `make workspace-app-delivery-check` proves this path
on the unmodified composition with a scripted agent, and
`make workspace-app-delivery-live-check` proves it with the installed Claude
Code building the application from its written spec.

## Limits

File and database provisioning, contract gateways, runtime agent elevation,
and active revocation fencing are later work. The installed `threads.read`
policy is registry authority for the selected application scope; this slice
does not add a service gateway or an immediate stop on revocation.

Destination migration execution requires a captured immutable registry view and
is not supplied by ordinary overlay activation. Automatic Hive enrollment and
discovery, remote workspace composition, destination Hub package transfer and
installation, and managed headless launch remain separate boundaries.

For the surrounding contracts, see [application contracts](../reference/applications.md),
[approvals](../reference/approvals.md), [sync and inbox](../reference/sync-and-inbox.md),
[Hub](hub.md) and [MCP configuration](agents/mcp.md).
