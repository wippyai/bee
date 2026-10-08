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

Receipt alone leaves the selected and active versions unchanged. The exception
is an application whose destination person explicitly enables **Following source**.
Following is off by default. The Library offers **Install & follow** for a hive
application and **Follow source**, **Pause updates** and **Pin version** in its
installed-version details. Consent belongs only to that destination and the
immutable identity `{source_node, source_workspace, component}`; a namespace
never establishes ownership.

The Governance activation worker consumes verified publications in source order,
stages and preflights their bytes, records review and selection, and prepares and
applies through the existing activation owner. A newer version reuses the live
installed approval only when authority is equal or narrower and no migrations
are pending. Expanded permissions, exposure, audiences or caller mappings, and
pending migrations raise one local request in **Needs you**. A general approval
lease does not authorize expansion by the follower.

The destination persists consent, publication cursor, version and bytes digests,
the pending activation identity, and the last follow outcome. Rollback,
equivocation and versions without a semantic ordering are refused. One pending
source update serializes later publications; restart resumes its durable owner
receipts. A failed update retains the working overlay. Pause and pin stop
following; going back pins the application, and removal turns following off.
The Library shows following state and the last update outcome. Following grants
no source-side automatic-publication permission: each node authorizes its own
publication and activation independently.

A destination stages the same source version independently from other
destinations. Its plan, selection, approval, activation receipt and overlay stay
on that destination.

## Applications from Hub

The Library stages a Hub application through the same destination plan and
activation owner as an overlay application. Type `application`, a `bee.app`
entry or an `ns.requirement` capability request selects governed delivery.
Verified catalog entries supply the immutable artifact; `hub_resolver` resolves
its closure against the destination registry and host package ceiling.

One local approval covers the application, capability grants and pending
migrations. `app.database` provisions the application's database, both its
migrations and runtime code use that grant, `agent.tools` offers its selected
functions, and `tests` discovers its tests by installed application association.
The declared menus place the application in the shell. Library packages and
Bee self-update retain their dependency-root publication path.

## Review and activation

The Library shows the destination-local plan: a person-facing version screen,
and, under Details (T), the measured artifact,
preflight report and report digest, diagnostics and remedies, pending migrations,
and entries added, changed or removed against the captured composed base. It
also shows selection, approval and activation state. A malformed report,
blocked preflight or stale plan cannot be selected or prepared. Preparation is
acknowledged as `approval_bound` before the person decides in Needs you. The approval
names applying and recovering the exact version until it is replaced or removed;
host admission remains required. Apply advances acknowledged owner revisions
through consumption, authorization and application. An unknown answer retains
the same receipt key and stops; an unchanged revision requires inspection before
another step.

The activation owner re-resolves and re-preflights immediately before applying.
It applies only the exact reviewed definitions through a generation-fenced
overlay API and records the observed outcome. A generation conflict or a base
that changes during the operation leaves an explicit uncertain or refused
result; the owner does not infer success or write registry history. Public
failures preserve the owner's code and cause; status reads the committed intent.
Restart recovery restores only the previously authorized desired intent. Native
durable-shadow permission belongs to the private activation and recovery owner
scopes; applications still require exact host admission and person approval.
After an exact native effect is observed, the owner remeasures the composed
definitions before recording the outcome; an unchanged durable base revision
does not postpone that observation.

For an admitted durable shadow, the external base binds the replaced entry's
identity, kind and registry-owned module. The exact incoming definition is
bound by the candidate; its replaced body is not an external dependency.
Referenced external definitions, other entries in the selected namespace and
the host's kernel manifest remain measured. This base stays stable after native
shadow application, so supervised activation can settle its own apply. A complete
replacement that omits an existing durable shadow is refused because the runtime
does not expose the original definition for final-state reference validation.
Settings' explicit disable operation removes shadows through the native owner,
which restores their original definitions. Its confirmation names the workspace,
the one-operation duration, and removal lasting until edit mode is enabled again.

### Protected kernel

The host-owned `bee.gov:protected_kernel` entry is the trust map no activation
profile can open, however permissive. It names every shipped namespace a
host-selected security scope lives in or is reached from (`bee.app`,
`bee.approvals`, `bee.apps`, `bee.capability`, `bee.credentials`, `bee.deps`,
`bee.docs`, `bee.env`, `bee.executor`, `bee.gateway`, `bee.git`, `bee.gov`,
`bee.harness`, `bee.hive`, `bee.hub`, `bee.node`, `bee.persist`,
`bee.placement`, `bee.resources`, `bee.security`, `bee.shell`, `bee.sync`,
`bee.threads`, `bee.ui`, `bee.values` and the shared driver namespaces
`bee.driver.binding`, `.codec`, `.descriptor`, `.locate`, `.permission`,
`.profiles` and `.transport`), each covering its child namespaces. Each
driver's own `bee.driver.<name>` namespaces stay under governance so workspace
drivers can be delivered. The kernel also names exact host entries: itself,
`bee.gov:activation_profiles`, `bee.gov:publication_profiles`,
`bee.driver:types`, `bee.driver:driver`, `bee.driver:locate_facet` and the
host bindings `bee:definition`, `bee:workers`, `bee:terminal`, `bee:os`,
`bee:env_path`, `bee:env`, `bee:role`, `bee:db_path` and `bee:db`. Its
`super_edit` list is the host's explicit carve-out: Bee selects
`bee.apps.settings` and `bee.shell`. A namespace the host deliberately names
there is the only protected namespace a super-edit profile may replace; an
empty list opens nothing. An exact admitted super-edit grant keeps that opened
namespace out of transitive kernel dependency traversal. Explicitly named kernel
entries stay protected even within a carve-out.
Both destination resolvers read it from the destination registry, include it in
the approval base, and pass it to preflight, which fails closed without it. Preflight computes the
kernel as the named definitions plus the code and wiring they reference
transitively (registry records and policies are protected by name only, so an
application they describe stays upgradable) and reports `PROTECTED_KERNEL` for
a plan that defines or replaces a kernel entry or dependency, declares a
protected namespace, updates a package that owns kernel definitions, or aims a
requirement target into the kernel. The kernel changes only through the host
composition and a person-confirmed native upgrade.

A host may open a protected namespace to one narrow, time-bounded profile: a row in `bee.gov:activation_profiles` that carries `expires_at`. Such a
super-edit row is refused unless it withholds auto start
(`allow.auto_start: false`), names a dedicated approver policy whose name
begins `super-edit` and which the host declares with `confirm: explicit` and at
least one approver, and carries no `allow.grants` entry for `security.*`,
`funcs.security`, `process.security` or a registry apply action. The
destination refuses an expired row before any effect, so the window closes
without a further write.

Bee Settings exposes a person-only **Edit mode** action. It accepts an exact
list of namespaces and a duration up to 24 hours, then asks the person to
confirm that list. The protected host writer adds one profile per namespace;
it refuses protected namespaces outside the host carve-outs, withholds auto start
and security or registry grants, admits the terminal rendering module `tty`, and
requires an explicit `super-edit` approver. Publication derives its source and
overlay owner from that existing activation profile, uses the overlay resolver,
and refuses the source after the edit grant expires. Author the namespace as the
overlay ID; freeze `entries.json` and request delivery of that source. Agents and overlays
cannot call this writer. Settings can disable the current workspace's profiles
and remove their overlay entries. The Edit mode pane reads the current host
profiles on entry and after execution replacement, so removal remains visible
when the initiating Settings execution is reloaded. Enabling a namespace that already has a
super-edit profile requires disabling it first.

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

The `delivery` tool requests delivery of a frozen artifact and reads a staged
version's activation status. Its destination is the agent's own workspace
unless it names that workspace explicitly. Once the destination's preflight is
ready, the same request records the requester's review and selection and
prepares the activation, which asks the person once: Needs you opens on the
desktop with that approval, and approving it lets the activation worker apply
the exact intent. When the person denies it, or the approval expires or is
withdrawn, the worker settles the activation as `denied`, `expired` or
`withdrawn`, which never reaches the registry, and closes the request with the
approval owner (`activation_closures`, `close_activation`). The version returns
to Library, Shared, and requesting delivery again prepares a fresh activation
under new keys that asks the person anew. The `publish` tool can publish only an exact applied version,
and a host may place it behind an approved access trait. Neither tool can
approve or write an overlay.

Delivery requests retain `workspace_id` for the destination runtime target and
`source_overlay_id` for the authoring identity. Internal services may use other
storage fields, but those are not public authoring vocabulary.

A session without the separately gated `publish` tool can still deliver: after
local review, approval and successful apply, the person publishes the locally
applied version through Governance's publication owner, not a direct registry
write. The destination sees it in the Library under Shared, from the bee that
published it (named by what that bee's node reports) and, when the publishing
session is known, made by the agent it runs, and Install there reviews, selects and prepares it; the person
approves its own activation in Needs you. Content travels; grants and decisions remain
destination-local.

## Workspace applications

Use `restart_policy: never` for an application without checkpoints. `automatic`
or `manual` requires a nonempty `resume_schema` of at most 80 characters without
control characters. Preflight reports `APPLICATION_CHECKPOINT` when this
metadata would prevent the desktop from opening the application.

A fresh install delivers an application a workspace's own agent authors to
that workspace without host configuration, and still only after the person
approves it. The shipped `bee.gov:publication_profiles` sets
`workspace_applications: true`, and the shipped `bee.gov:activation_profiles` carries a `workspace_applications` rule:
the approval policy (`workspace-application-delivery`, decided in Approvals by
the person, as `bee.security.approvals:approver_policies` ships it), the admitted entry kinds and
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
component and namespace `app.todo`, exactly one `process.lua` entry declaring
`meta.type: bee.app` under the ordinary application boundary, and the private overlay owner
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
single target must be its own `bee.app` process entry at
`.security.policies +=`, except a `hive.expose` request, whose target is one of
the artifact's own Hive operations at the requested mode. A named operation
declares an authored `meta.hive_service`, a `meta.hive_operation` containing
`name`, `revision`, `input` and `output` schemas, and `meta.application_ref`
pointing to its owning application in the same measured artifact. Artifact
validation checks those declarations and refuses duplicate names within an
application's service. Application operations declare no security of their own;
they use the installed application's grants. The supervisor resolves these declarations only within
the installed grant owner's overlay; namespace spelling grants no routing or
invocation authority.
Application and operation targets may occupy different namespaces in the same
measured artifact. The destination
resolver checks the request against the host-owned `bee.capability:catalog`, preserves the normalized parameters, reason, target, and catalog/template
revisions in the measured candidate, and includes the catalog definition in
the candidate's external-base digest. The request grants no policy. Preflight
refuses app-shipped `security.actor` and `security.groups` on every entry with
`SECURITY_DENIED`.

For the shipped `contract.call` capability, `meta.parameters` contains an exact
`binding` and a nonempty `methods` list. For example, an application requests
the sessions catalog method with this registry entry in `entries.json`:

```json
{
  "id": "app.example:status_read",
  "kind": "ns.requirement",
  "meta": {
    "value_kind": "security.policy",
    "capability": "contract.call",
    "parameters": {
      "binding": "bee.threads.sessions.binding:catalog_binding",
      "methods": ["list"]
    },
    "reason": "List the launch definitions this node can open."
  },
  "data": {
    "targets": [{"entry": "app.example:app", "path": ".security.policies +="}]
  }
}
```

Replace `app.example` with the application's admitted namespace. The components
tool can read the destination's `bee.capability:catalog`; its host-selected
parameter schema remains authoritative. This declaration requests permission;
the person still reviews and approves the exact binding and methods locally.

The catalog currently describes `workspace.files.read`, `workspace.files.write`,
`app.database`, `threads.read`, `threads.message`, `agents.launch`,
`contract.call`, `http.api`, `hive.expose`, `hive.view`,
`desktop.application_stop`, `hub.manage`, `hub.self_update`,
`gov.delivery.manage` and `gov.delivery.activate`. Its decoder bounds relative subpaths, lists, identities and
HTTPS origins; it also carries a never-list for execution, environment and
credential access, registry and scope management, approval decisions, core
databases, and auto start. `bee.capability:model` expands templates into
proposed operation/resource/scope values, compares grant scopes semantically,
renders host-authored permission text with combined read-to-egress lines, and
builds revocation reports for Governance registry grants, Resources SQL grants
and Gateway MCP trait grants. Each component keeps its own grant store.
Runtime elevation uses the same resolution before filing approval and refuses a
capability whose resource source is a fixed host resolver, since it cannot be
written as a workspace association grant.
For workspace application delivery, the host resolves these values before
approval and shows the full set, changes from the installed grant, and any
combined data flows in Approvals. `threads.read` with `scope: owned`,
`workspace.files.read`, `workspace.files.write`, `app.database`,
`threads.message`, `agents.launch`, `contract.call` and `http.api` have
installable host entries. A `hive.expose` grant installs a host-owned policy
over exactly the approved operations into `bee.security.hive:hive_exposure_scope`.
The scope defaults to no exposure. The supervisor's `application.call` path
checks live admission, the installed exposure grant, exact mode/operation
permission and the authenticated peer node's approved audience. Host admissions
exclude installed application overlays, and portable artifacts cannot declare
host admission metadata. The receiver validates input and output schemas and
runs open-mode calls under the installed app's
actor and scope. Four execution slots and a 64-call queue bound dispatch;
queued calls repeat authorization before execution. The supervisor's deadline
reply reports outcome unknown and keeps the slot occupied until the function finishes.
Policy-mode application calls require trusted subject mappings and fail closed
while that path is unavailable. Existing service routes still forward without
the application exposure gate. The app-facing `hive.call` capability/facade is
not implemented. Exposure policies stay out of application execution scopes
and exposure requirements do not attach those policies to app functions.
For `application.call`, `application` accepts the existing exact definition ID,
an immutable `{source_node, source_workspace, component}` object, or an
`{alias}` object. A source identity also resolves through the live governed admission and its
destination-selected component profile. The destination supplies additional
identity and alias mappings as
`registry.entry` records with `meta.type: bee.hive.application_address`:

```json
{
  "id": "host.sdk:address",
  "kind": "registry.entry",
  "meta": {"type": "bee.hive.application_address"},
  "data": {
    "workspace_id": "destination-workspace",
    "application": "app.project_sdk:app",
    "overlay_owner": "destination-approved-installation-owner",
    "identity": {
      "source_node": "author-node",
      "source_workspace": "project_sdk",
      "component": "app.project_sdk"
    },
    "aliases": ["project-sdk"]
  }
}
```

This record is destination host configuration, separate from the portable
application manifest. Portable artifacts cannot declare it, and records in
installed application overlays cannot resolve addresses. The mapping's owner
must match the live installed grant; a governed admission must also match that
owner and source node/workspace. The destination rejects ambiguous identities
or aliases and resolves a queued call's address again before execution. The
service and operation retain their authored metadata names. Version is
separate from identity and cannot appear in the address object. An address
adds no exposure or execution authority. Calls to durable package entries
remain unavailable through this receiver until their ownership can be verified
independently of overlay shadows.

A file grant installs a host-created
`fs.directory` at a verified subroot of the destination workspace's own
folder: the destination reads the workspace's root and subpath from the node
workspace catalog (through `bee.node.binding:read` under
`bee.node.security:workspace_folder_read_policy`), the grant record measures
that folder, the pinned runtime confines traversal and symlinks below the
volume, a read grant is read-only at the filesystem boundary, and private
paths and Bee state (`.wippy`) are refused, including ancestor subroots that
would expose them. A database grant installs a host-provisioned dedicated
SQLite store under `bee.capability:app_databases` (rooted at `BEE_APP_DATABASE_ROOT`, default `.wippy/app-db`), outside the readable tree, with a `db.get`-only policy on that store.
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
`function.lua`, `library.lua`, `ns.definition`, `ns.requirement` and `registry.entry` entries.
`ns.definition` describes the package; it carries no executable authority.
`function.lua` includes declared tools, migrations and tests. Native imports are limited to
`tty`, `process`, `channel`, `json`, `time`, `uuid`, `base64`, `hash`, `funcs`,
`fs` and `sql`; contract and HTTP reach goes through the gateway. The application binding gets
the `bee.node.security:application` policy group and `thread_access: none`; the
generated grant policies add exactly the approved file, database and thread
reach. `store.memory` and `store` are outside this ceiling. These are ceilings,
not a grant to launch any agent definition: launch remains subject to the
host's separate definition and application policies. 

The shipped `packages` ceiling beside it is the wider rule for installed
package delivery: it additionally admits `security.policy`,
`contract.binding` and `env.variable` entries with the `registry` and `system`
native modules, still under the ordinary application boundary, no thread
access, and the same explicit person approval. Governed admission bindings
carry the runtime flags `appearance_write`, `application_stop`,
`scope_management` and `close_grace_ms` alongside policies and thread access,
so a package record states the same binding the broker enforces.

### Can a workspace application get its own database?

Yes, through the `app.database` capability: the destination binds the
requested logical name to a host-provisioned dedicated SQLite store, runs the
application's migrations against it in append-only order before the
application starts, and admits only that store through the generated policy.
The opt-in application checkpoint of at most 65,536 bytes remains for small
resume state. Closing the live view removes its resume record, while the
database file persists.

A person installs the shared version from the Library (System menu), which
stages, reviews, selects and prepares it, approves the request in Needs you,
and follows the version until the activation owner settles it; the application then appears in the menus
its `menus` field names.

## Limits

Runtime agent elevation is implemented through the gateway `request_capability` and
`capability_status` tools: an approval bound to the authenticated thread and
attempt consumes once and writes one thread-actor resources grant the attempt's
placement resolves. The host verifies the named resource association and
requested access before approval and before consuming an approved decision.
Active revocation fencing withdraws a fenced attempt's grants: Resources
`revoke` and `revoke_all` pass their fenced attempt IDs to Placement, which
rechecks each recorded grant and requests a cooperative stop when that attempt
lost access.

Destination migration execution requires a captured immutable registry view and
is not supplied by ordinary overlay activation.

For the surrounding contracts, see [application contracts](application_contracts.md),
[approvals](approvals.md), [sync and inbox](sync_and_inbox.md),
[component/hub](../component/hub.md) and [MCP configuration](mcp_configuration.md).
