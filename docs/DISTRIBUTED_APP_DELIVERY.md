# Distributed application delivery

Status: immutable candidate identity, generic Hive transfer, verified replica
reading, destination plan storage, the activation ledger, private-overlay
resolution and the destination-owner state machine are implemented in source.
The App Delivery application presents destination-local review, selection,
activation and status; decisions remain in the existing Approvals owner. The
real two-runtime gate transfers two distinct versions of a private application
that is unavailable on Hub, then exercises destination review, update, recovery
and rollback. Modules reaches the publication facade without receiving registry,
overlay or Sync authority. Ordinary Bees can now consume a strict persisted Hive
profile; public invitation/profile creation, multi-project joined identities and
destination migration execution remain unfinished.

Publishing replicates content. It never installs, activates, or grants authority
on another Bee. The sender freezes its authoring workspace and prepares one
source-owned immutable component version locally. Preparation stores exact bytes
without appending the Sync feed. The same local App Delivery flow must stage,
review, select, approve and apply those bytes before publication may append their
descriptor to the feed. That version contains no destination node, workspace,
plan, approval or host policy. A destination receives the bytes through the
existing authenticated Hive mesh, measures them again, and constructs its own
candidate and preflight against its current registry and policy.

## Version behavior

Generic Hive sync discovers immutable **available versions**. It does not make a
replica into an authority and it does not select a version for an application.
The source owns version descriptors and content digests. Each destination owns its
follow configuration, replica cache, selected version, review/approval record and
activation. Publishing v2 can therefore make v2 available on another Bee while
its selected and running v1 continue unchanged, including after restart. Updating
is an explicit destination action, the same distinction Hub makes between an
available release and an applied update.

The shared receiver stores every source-qualified immutable version under
`(source owner, feed, version key)`, with a separate durable source cursor. It
must never feed remote data back through `bee.sync:store` as a local append: that
would change ownership and create replication loops. A source withdrawal stops
future distribution; it does not uninstall or deselect a version that a destination
already selected.

The delivery flow is deliberately small:

1. Freeze an authoring workspace and prepare a destination-independent component version locally.
2. Stage, review, select, approve and apply that exact local version, then publish it.
3. Transfer bounded chunks. Interrupted transfers remain `receiving`; only a
   complete length- and digest-verified replica becomes `available`.
4. Ask the destination governance owner to read that local replica by its complete
   source/feed/key/descriptor identity. It verifies the canonical application
   envelope, resolves the destination candidate locally, runs local preflight and
   stores those exact bytes as a `staged` plan with a durable receipt.
5. Present destination-local review and use the existing Approvals owner for a decision.
6. Persist desired definitions and reconcile the destination-owned overlay only after
   its approval and exact runtime preconditions hold.

No source approval, credential, filesystem root, process, mount, registry writer,
or overlay handle crosses this boundary. Duplicate delivery reuses its receipt.
The same immutable source version can be staged independently by many destinations;
their plans, selections, approvals and overlays never cross that boundary.

Overlay activation uses the existing owner-local, generation-fenced overlay API.
Immediately before apply, governance re-resolves and re-preflights the selected
candidate in the destination context, then applies the exact reviewed definitions
through its owned overlay generation. An overlay-generation conflict retires that
attempt and requires another preflight; overlay activation never writes registry
history.

Durable registry publication is a separate adapter. Its atomic composed-base CAS
remains unavailable and must not be approximated with a Lua pre-read. That missing
durable-publication guard does not block the overlay path.

Implemented transport and artifact slices:

1. `bee.sync` stores source-qualified immutable versions with resumable bounded
   chunks. Finishing one blob does not advance source discovery; a catch-up owner
   commits its cursor separately after handling every descriptor in the range,
   using an expected-cursor compare-and-set. The native supervisor admits the
   receive operation through its generic policy route.
2. `bee.governance:artifact` produces and verifies the canonical bounded bytes for
   exact resolved registry definitions. The replica layer treats those bytes as an
   opaque immutable version and never selects or executes them.
3. `bee.governance:delivery` wraps the source identity, component version and exact
   artifact in `bee.governance-application-version@2`. Its sync descriptor derives
   the source-qualified component/version identity and uses the exact envelope
   length and digest. It carries no destination candidate or preflight report.
4. `bee.sync:replicas.read` returns a descriptor and content only from an available
   local replica after rechecking both descriptor records, every chunk, total
   length and the final content digest.
5. `bee.governance:destination.stage_replica` accepts only the complete local
   replica identity and an idempotency key. It derives the plan request internally
   and requires the candidate destination to equal the opened local plan owner.

The native two-runtime supervisor acceptance carries two exact versions of a
private migration-free application as
`bee.governance-application-version@2` envelopes through the generic receiver.
The destination service stages, reviews and selects v1, then receives and stages
v2 without changing the v1 selection. It obtains a local approval through the
Approvals owner, applies v1 to the destination overlay and, after destination
restart, reconstructs that overlay from the authorized desired intent while v2
is still staged. The test then explicitly updates to v2 and rolls back to v1.
Its source helper builds exact private definitions without Hub and hands those
bytes to the production publisher. The test
does not drive the terminal Modules UI. Destination staging, resolution,
approval, activation and recovery all use the production services.

The destination now has a durable internal plan store. Available versions retain
their exact candidate, artifact and preflight bytes; local review, explicit
selection and approval binding advance through CAS revisions and bounded retry
receipts. Selection remains separate from receipt of a replicated version.

The owner-local overlay materializer is now implemented and tested. It accepts
only exact artifact entries, replaces one logical overlay, relies on one native
overlay generation compare-and-set, and creates no durable registry version. A
generation conflict returns to the destination owner so it can rebuild context
and rerun preflight before another attempt.
It is still internal and receives its owner identity from the destination
service rather than the replica.

Migration 5 adds an internal destination activation ledger. Immutable intent
facts bind the selected source plan, host-selected overlay owner, exact local
resolution, artifact and preflight measurements. Mutable approval/consumption
progress is separate. A destination slot records the authorized desired intent
separately from the last observed applied intent, so restart recovery cannot
follow a newer staged or selected version. An uncertain apply can later be
settled only from observed evidence.

`bee.governance:activation_measure` is the destination-local measurement seam
for the Hub resolver. It accepts a selected, accepted local plan plus a
host-produced resolved candidate and current context. It remeasures the exact
reviewed artifact, requires every candidate entry digest to match those bytes,
runs a fresh local preflight, rejects pending migrations and dependency
directives, and produces the immutable resolution/report blobs stored by the
ledger. The activation approval proposal binds the resulting authorization
digest and its consumption bridge verifies the exact consumer, proposal and
effect receipt while preserving structured revalidation details.

`bee.governance:activation_owner` now joins those internal pieces without
gaining transport or decision authority. Preparation reads the current accepted
selection, invokes a host-supplied resolver, measures the destination facts,
persists an immutable intent, and requests the exact local approval. Each resume
step crosses one durable phase. It rechecks the current selection immediately
before recording `consuming`, reconciles the same approval effect after a crash,
sets the desired pointer only with a verified consumption receipt, and performs
one host-supplied owner-overlay apply. Recovery reads only that desired intent;
a later replicated, staged or selected version cannot replace it. Exact overlay
observation settles an uncertain apply. A settled desired version is remeasured
and restored when its process-local overlay is absent after restart; each later
drift observation has its own revision-fenced receipt. The destination service
supplies its host configuration and real approval executor. The bundled App
Delivery application calls that service for staged plan listing, local review,
selection, activation and status/recovery presentation. The existing Approvals
application remains the decision surface; App Delivery does not publish or send
candidates.

`bee.governance:hub_resolver` now implements destination Hub resolution over
the runtime registry preview. It applies the preview delta to the captured
state, walks the selected package closure, keeps unchanged definitions from
every selected module and produces an overlay with no dependency directives.
Package ownership and immutable module digests come from registry-owned preview
metadata. Destination policy and migration ledgers come only from the host.
Focused acceptance proves exact artifact equality, unchanged-entry retention,
dependency-directive removal, registry ownership and unchanged host policy.
The two-runtime test constructs its transmitted private artifacts directly and
then exercises the production publisher, generic distributor, private-overlay
resolver and destination owner service.
Modules separately proves its production Governance binding from source and a
source-free pack. An unprofiled component is refused instead of publishing its
Hub dependency overlay.

The runtime also defines the canonical receive surface
`stream.pipe(peer, limit)`. Its Stream handle stays in the receiving actor's
resource table and its opaque offer is routing metadata, not authority. The
protected mesh implementation is currently a proven local runtime candidate,
not the default runtime service. Once that runtime work lands, `bee.sync` may
use it for bulk bytes while retaining the same immutable descriptors, durable
replica receipts and Governance boundary.

The remaining destination work is:

1. Add destination migration orchestration after the runtime can invoke a
   captured function against an ephemeral immutable registry view. Ordinary
   overlays cannot provide this safely: they publish globally, trigger normal
   lifecycle handling, reject overlapping IDs and reject cross-owner imports.

Acceptance must prove that source v2 leaves a destination's selected and active
v1 unchanged across restart; duplicate/lost transfers do not duplicate versions;
equal identities with different content conflict; revoked sources stop new data
without deleting verified bytes; and collection retains any selected, pending or
resumable version.
