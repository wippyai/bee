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

### Protected kernel

The host-owned `bee:protected_kernel` entry is the trust map no activation
profile can open, however permissive. It names every shipped namespace a
host-selected security scope lives in or is reached from (`bee.gov`,
`bee.governance`, `bee.security`, `bee.approvals`, `bee.apps`, `bee.launch`,
`bee.gateway`, `bee.harness`, `bee.credentials`, `bee.placement`,
`bee.placement.native`, `bee.resources`, `bee.threads`, `bee.hive`, `bee.env`,
`bee.sync`, `bee.host`, `bee.session`, `bee.client`, `bee.desktop`,
`bee.terminal`, `bee.node` and `bee.workspace`, which cover their child
namespaces) and the exact host selectors `bee:approver_policies`,
`bee:capability_catalog`, `bee.env:gov_activation_profiles`,
`bee.env:gov_publication_profiles`, `bee.deps:gov`, `bee.deps:approvals` and
itself. Its `super_edit` list is the host's explicit carve-out: an empty list
in the shipped composition opens nothing, and a namespace the host deliberately
names there is the only protected namespace a super-edit profile may replace.
Both destination resolvers read it from the destination registry, include it in
the approval base, and pass it to preflight, which fails closed without it. Preflight computes the
kernel as the named definitions plus the code and wiring they reference
transitively (registry records and policies are protected by name only, so an
application they describe stays upgradable) and reports `PROTECTED_KERNEL` for
a plan that defines or replaces a kernel entry or dependency, declares a
protected namespace, updates a package that owns kernel definitions, or aims a
requirement target into the kernel. The kernel changes only through the host
composition and a person-confirmed native upgrade.

A host may open a protected namespace to one narrow, time-bounded profile: a
row in `bee.env:gov_activation_profiles` that carries `expires_at`. Such a
super-edit row is refused unless it withholds auto start
(`allow.auto_start: false`), names a dedicated approver policy whose name
begins `super-edit` and which the host declares with `confirm: explicit` and at
least one approver, and carries no `allow.grants` entry for `security.*`,
`funcs.security`, `process.security` or a registry apply action. The
destination refuses an expired row before any effect, so the window closes
without a further write.

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
approves it. The shipped `bee.env:gov_publication_profiles` sets
`workspace_applications: true`, and the shipped
`bee.env:gov_activation_profiles` carries a `workspace_applications` rule:
the approval policy (`workspace-application-delivery`, decided in Approvals by
the person, as `bee:approver_policies` ships it), the admitted entry kinds and
native modules, and the admission policies and thread access of the one
application entry.

The rule applies to an overlay whose name is lowercase letters, digits and
underscores starting with a letter, authored on this node or, while the rule's
`hive` flag is `true` (the shipped value), received over Hive from another
node. A Hive-received overlay is admitted the same way on its destination: the
destination instantiates its own profile and capability catalog, its own
person approves the first install, and it installs its own grants. Grants
never travel with an artifact: an upgrade reuses only the destination's own
installed grant record under the same containment rule as a local upgrade. An
application name belongs to the source node whose activation holds it; an
overlay with the same name from another node is refused instead of replacing
it. With `hive: false` the rule covers only overlays this node authored. Overlay `todo` gets
component and namespace `app.todo`, the application entry `app.todo:app` under
the ordinary application boundary, and the private overlay owner
`bee.gov.apps:<workspace_id>.todo`. Nothing under the
rule starts itself: an entry that declares `lifecycle.auto_start` is refused at
preflight with `AUTO_START_DENIED`, so the application runs only while the
broker has it open. An explicit profile row for the same source takes
precedence; it admits auto start unless its `allow.auto_start` is `false`. A source the rule does not
cover is refused with the rule and the profile entries a host adds.
Previously installed workspace applications retain their measured overlay
owner, grant IDs, and activation receipts when Bee resumes them.

The shipped workspace application profile also admits `ns.requirement` entries
for capability requests. A request declares `meta.value_kind: security.policy`,
`meta.capability`, bounded `meta.parameters`, and a printable `meta.reason`. Its
single target must be its own `bee.application` process entry at
`.security.policies +=`, except a `hive.expose` request, whose target is one of
the artifact's own Hive operations at the requested mode. The destination
resolver checks the request against the host-owned `bee:capability_catalog`,
preserves the normalized parameters, reason, target, and catalog/template
revisions in the measured candidate, and includes the catalog definition in
the candidate's external-base digest. The request grants no policy. Preflight
refuses app-shipped `security.actor` and `security.groups` on every entry with
`SECURITY_DENIED`.

The catalog currently describes `workspace.files.read`, `app.database`,
`threads.read`, `threads.message`, `agents.launch`, `contract.call`, `http.api`,
`hive.expose`, `hive.view`, `hive.remote_view`, `workspace.catalog.read`,
`workspace.catalog.manage`, `workspace.host.lease`, `desktop.application_stop`,
`hub.manage`, `gov.delivery.manage` and `gov.delivery.activate`. Its decoder bounds relative subpaths, lists, identities and
HTTPS origins; it also carries a never-list for execution, environment and
credential access, registry and scope management, approval decisions, core
databases, and auto start. Pure helpers expand templates into proposed
operation/resource/scope values, compare two resolved grant sets semantically,
and render host-authored permission text with combined read-to-egress lines.
For workspace application delivery, the host resolves these values before
approval and shows the full set, changes from the installed grant, and any
combined data flows in Approvals. `threads.read` with `scope: owned`,
`workspace.files.read`, `workspace.files.write`, `app.database`,
`threads.message`, `agents.launch`, `contract.call` and `http.api` have
installable host entries. A `hive.expose` grant installs a host-owned policy
over exactly the approved operations into the supervisor's exposure scope;
the destination audience table admits the operation's peers, and policy-mode
operations still check the caller through the destination principal mappings.
A file grant installs a host-created
`fs.directory` at a verified subroot of the destination workspace's own
folder: the destination reads the workspace's root and subpath from the node
workspace catalog (through `bee.workspace.catalog:read` under
`bee.security.gov:workspace_folder_read_policy`), the grant record measures
that folder, the pinned runtime confines traversal and symlinks below the
volume, a read grant is read-only at the filesystem boundary, and private
paths and Bee state (`.wippy`) are refused, including ancestor subroots that
would expose them. A database grant installs a host-provisioned dedicated
SQLite store under `bee.env:app_databases` (`.wippy/app-db`, created by the
host), outside the readable tree, with a `db.get`-only policy on that store.
An application reads the identities of its own granted volumes (by subpath)
and database (by name) from `bee.gov.binding:granted_resources`, which answers
only for the calling application's live grant; it never embeds a
host-generated identity, so the same artifact works on every workspace and
node. The shipped module ceiling includes `funcs` so the installed policy can
authorize calls to the Threads owner, which checks the application's actor
membership, plus `fs` and `sql` so file and database grants are callable
through the granted identities shown at approval. A child-thread message
grant authorizes calls to the Threads owner's message verbs, which check the
caller's membership; a launch grant authorizes the application launch facade
call and `bee.harness.launch` on exactly the approved definitions, so the
installed policy reaches the facade and the facade then checks the same
generated policy for the named definition; the attempt is bound to the
caller's workspace and admits no inherited app grant. The
runtime authorizes `contract.call` on the bare method name and
`http_client.request` on the URL alone, so contract and HTTP grants never give
an application those actions. They authorize `funcs.call` on the host gateway
(`bee.gov.binding:contract_call` with `{binding, method, arguments}`,
`bee.gov.binding:http_request` with `{method, url, headers, body, timeout}`).
The gateway authenticates the broker-created application principal, reads
that application's own live grant record and admits only the exact binding and
method, or an approved method under the approved origin and path prefix
(traversal and encoded separators refused; a response that arrives from
outside the prefix is withheld). A contract callee runs under the original
application actor with none of the gateway's authority, so its owner checks
see the real caller and workspace: a grant for one binding, workspace or
application never reaches another.

On approval, one registry overlay transaction installs host-owned policies in
`bee.gov.grants`, fills the requirement defaults, and records the grant
set, digest, approval ID, and revision. The workspace application rule derives
its policy allowance, application binding and thread access from that live
record. A later version still receives artifact measurement and preflight. If
its resolved set is contained in the installed grant, it reuses that approval
and installs only the requested subset. Widening asks the person to approve
the delta; refusal leaves the installed version and grant intact.

The shipped `workspace_applications` ceiling admits `process.lua`,
`library.lua` and `ns.requirement` entries. Native imports are limited to
`tty`, `process`, `channel`, `json`, `time`, `uuid`, `base64`, `hash`, `funcs`,
`fs` and `sql`; contract and HTTP reach goes through the gateway. The application binding gets
`bee.security:ordinary_app_subsystem_boundary` and `thread_access: none`; the
generated grant policies add exactly the approved file, database and thread
reach. `store.memory` and `store` are outside this ceiling. These are ceilings,
not a grant to launch any agent definition: launch remains subject to the
host's separate definition and application policies. Although the catalog
also describes Hive exposure, this rule does not install that grant: Hive
exposure stays host-published.

The shipped `packages` ceiling beside it is the wider rule for installed
package delivery: it additionally admits `security.policy`, `registry.entry`,
`contract.binding` and `env.variable` entries with the `registry` and `system`
native modules, still under the ordinary application boundary, no thread
access, and the same explicit person approval. Governed admission bindings
carry the runtime flags `appearance_write`, `application_stop`,
`scope_management` and `close_grace_ms` alongside policies and thread access,
so a package record states the same binding the broker enforces.

The rule also names the host-composed package applications the catalog admits
without delivery: Hive Manager (`hive.view`, `hive.remote_view`), Timeline
(`threads.read`), Workspace Manager (`workspace.catalog.read`,
`workspace.catalog.manage`, `workspace.host.lease`), Host Processes
(`desktop.application_stop`, admitted with `application_stop`), Modules
(`hub.manage`), and Overlays (`gov.delivery.manage`, `gov.delivery.activate`).
Each entry reuses its reviewed static policies; a live host grant record for
the package owner adds capability-derived policy IDs beside them. Only
Settings, Console, Inbox and the harness window stay on the static admission
list.

### Can a workspace application get its own database?

Yes, through the `app.database` capability: the destination binds the
requested logical name to a host-provisioned dedicated SQLite store, runs the
application's migrations against it in append-only order before the
application starts, and admits only that store through the generated policy.
The opt-in application checkpoint of at most 65,536 bytes remains for small
resume state. Closing the live view removes its resume record, while the
database file persists.

A person reviews the staged plan in Start › Tools › Overlays, selects and
prepares it there, approves the request in Start › Tools › Approvals, and lets
Overlays step the activation owner until it settles; the application then
appears in the Start menu. `make workspace-app-delivery-check` proves this path
on the unmodified composition with a scripted agent;
`make agent-app-hive-e2e-check` also carries that agent-built application
across Hive to a second node, which admits it only through its own shipped
rule and person and opens it with its own grants; and
`make workspace-app-delivery-live-check` proves it with the installed Claude
Code building the application from its written spec.

## Limits

Hive exposure is later work. The installed file, database, thread, launch,
contract and HTTP grants are registry authority for the selected application
scope. Runtime agent elevation is implemented through the gateway
`request_capability` and `capability_status` tools: an approval bound to the
authenticated thread and attempt consumes once and writes one thread-actor
resources grant the attempt's placement resolves. Active revocation fencing is
implemented: an epoch advance reports its fenced attempts, and an owner fence
withdraws the fenced instance's thread delegation before stopping it.

Destination migration execution requires a captured immutable registry view and
is not supplied by ordinary overlay activation. Automatic Hive enrollment and
discovery, remote workspace composition, destination Hub package transfer and
installation, and managed headless launch remain separate boundaries.

For the surrounding contracts, see [application contracts](../reference/applications.md),
[approvals](../reference/approvals.md), [sync and inbox](../reference/sync-and-inbox.md),
[Hub](hub.md) and [MCP configuration](agents/mcp.md).
