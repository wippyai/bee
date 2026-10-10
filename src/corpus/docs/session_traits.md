# Agent profiles, traits and context

A saved `bee.agent-profile@3` has `name`, optional `role` (256 bytes),
`active_traits`, `requestable`, and `context`, alongside its driver, provider,
Bee permissions and placement choices. Each trait list holds at most 16 IDs.
Context holds at most 24 printable keys (128 bytes each), scalar string, finite
number or boolean values, and 8192 encoded bytes. Keys beginning `bee.` belong
to the host and are refused in profiles and spawn overrides.

Sessions `open` and `run`, MCP `session_open` and `session_run`, and the Lua
Sessions client accept the same optional
`overrides = {name?, role?, traits?, context?, workdir?, workspace?, input?}`.
The owner and MCP take it inside `spec`; the Lua client takes it beside
`definition` and `profile`. A profile reference is `{id, revision}`.
`traits` replaces the initial selection, including an empty list to select none.
It must fit the saved profile's active plus requestable traits, the launch policy,
and the spawning parent's admitted trait ceiling. Refusals name the trait.
A person saving an active built-in consent trait approves it for that saved
revision. Launches reuse that live grant without asking again. Agent writes
carry delegated provenance and still ask through Needs you. Application
extension traits still require approval of their exact revision, listens and
hooks. `requestable` controls what an agent may ask for later.
Legacy saved MCP consent-tool choices migrate to active consent traits in
storage; launch uses those explicit selections.

Profile context and override context compose into the session's fixed context;
overrides replace matching profile keys and host values win. MCP
`session {operation = "read"}` returns the composed context. Name and role
appear in the Agents list, Sessions catalog and thread title.

Agents use `profile_list {after_key?, expected_cursor?, limit?, definition_ref?, query?, sort?}`, `profile_get {profile_id}`, and
`profile_put {profile_id, expected_revision, idempotency_key, profile}` in their
bound workspace. Put uses the existing profiles contract's compare-and-swap
owner and delegated profile grant. Driver and parent ceilings still apply;
saving a gated trait cannot activate it. The editor offers Role, trait choices
(active, requestable or off, with gated traits marked "asks you"), and scalar
Context rows. Opening an agent also accepts a name, role and folder.

Launch policies declare gateway tools, trait access and fixed context through
`gateway_surface`. An access declaration inside that surface is normalized with
the host's tools; the former `gateway_access` policy field is refused.

## Build an app that listens to a session

Ship an ordinary `agent.trait` registry entry with `meta.application_ref` naming
your installed app. For example:

```yaml
- name: remember
  kind: registry.entry
  meta:
    type: agent.trait
    application_ref: memory:app
    title: Remember completed turns
  data:
    prompt: Remember facts from this session.
    tools: []
    listens: [turn.completed]
```

`listens` accepts `session.started`, `session.ended`, `prompt.submitted`,
`tool.before`, `tool.after`, and `turn.completed`. `hooks` accepts `session.start`,
`prompt.submit`, `tool.before`, and `tool.after`; selecting a trait with hooks
returns `UNSUPPORTED_CAPABILITY: hooks not yet supported` in phase 1.

A profile's `active_traits` seeds selection. An agent can also request an offered
trait through the existing access request. Needs you shows the app revision and
exact listens and hooks. The person's approval grants this workspace and session
only. Changed app revisions or declarations need fresh approval. Revocation ends
delivery; an agent's profile write cannot approve a trait.

As the app, call the existing `bee.threads:delivery` binding:

```lua
subscribe({trait_id = "memory:remember", idempotency_key = key})
```

Its `subscriptions` lists only this app's approved sessions, with `session_ref`,
`thread_id`, `trait_id`, and `subscription_id`. It returns up to 128 selections;
for a known session, subscribe directly:

```lua
subscribe({thread_id = thread, idempotency_key = key,
    filter = {session_ref = session, trait_id = "memory:remember"}})
page({thread_id = thread, subscription_id = subscription, limit = 32})
ack_page({thread_id = thread, subscription_id = subscription,
    page_id = page.page_id, scanned_through = page.scanned_through,
    idempotency_key = acknowledgement_key})
```

Use the contract's normal reply envelope. A page's `events` contains
`{id, kind, session_ref, thread_id, sequence, record_ref, turn_ref?, payload}`.
The payload contains the committed event content; completed turns include their
stored input and result. A `turn.completed` event also carries
`usage = {input_tokens?, output_tokens?, cached_tokens?, tool_calls?, coverage}`.
Unknown counters remain absent; reported zero remains zero. Coverage is
`unknown` when no counters are known and `partial` when any are known. Native
hook and stream summaries count once, and tool calls deduplicate by call ID.
Process the page durably, then acknowledge its exact
identity and extent. An empty filtered page can still advance through unrelated
records: acknowledge it when it has a `page_id`. Outstanding pages replay until
acknowledged. The host owns the consumer identity, cursor and durability, so a
restarted app uses the same subscription. `resume` reattaches after an owner
restart or reactivation. Every page and acknowledgement rechecks consent.

Selection starts after the committed sequence at approval. Delivery excludes
other sessions on the thread and inactive intervals. Revocation invalidates
outstanding pages. Listening grants no thread membership; an app stores its own
index and uses its separately authorized Threads access for reading it.
