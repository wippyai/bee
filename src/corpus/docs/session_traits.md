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
appear in the Sessions view in Agents, Sessions catalog and thread title.

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

## Installed application traits

Every installed application admitted with a live `agent.tools` grant appears in
this workspace's agent trait catalog. Its title comes from the app declaration;
its prompt describes the app's tools and their names. Its trait ID comes from
the same identity owner as application membership: the admitted definition,
workspace and overlay owner. Read the catalog and use that ID; do not guess a
namespace or choose Hub and Library to find an app.

MCP `session {operation = "read"}` lists these traits. Put an app ID in profile
`active_traits` or `requestable`, or in spawn `overrides.traits`, like any trait.
Parent and profile ceilings still apply. Activate through `session` selection;
when consent is needed, use `request_access` with that trait ID and a reason,
then `access_status` for the returned approval. Needs you names the app and its
exact tools. Approval activates only that app's tools for this session. Agent
profile writes and delegated launches cannot approve themselves.

The generic `bee.app:tools` selection gives no blanket application tool access.
Each app has its own approval and selection. Calls use its advertised aliases;
arguments and replies retain their registry schemas and the node runs each call
as the app with its live grants. Uninstall removes the trait from existing
sessions. Upgrades refresh its description and tools and invalidate approval of
a changed declaration. A withdrawn grant removes the tools as well.

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
`prompt.submit`, `tool.before`, and `tool.after`. The Sessions catalog reports each driver's `hook_capabilities`
as `{point, supported, allowed_results, reason}`. Unsupported points refuse
activation, including CLI points omitted by the binding's launch policy.
OpenCode observations cannot intercept these points.

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

## Write a synchronous hook

Add `hooks: [prompt.submit]` to the trait and ship one `function.lua` entry
with `meta.type: bee.session.hook`, `meta.application_ref` naming the app,
`meta.application_revision` matching its approved revision, and `method: hook`.
The host discovers this entry by metadata and runs it as the approved app with
its admitted scope.

```lua
local M = {}
function M.hook(point, turn)
    if point == "prompt.submit" then
        return {kind = "add_context", text = "The project uses Lua."}
    end
    return {kind = "pass"}
end
return M
```

`turn` carries host-authenticated `invocation_id`, `occurrence_id`, `session_ref`,
`thread_id`, `workspace_id`, `trait_id`, optional `turn_ref`, `tool_name`,
`tool_call_id`, and point-specific `text`, `input`, or `output`. Each hook sees
accepted changes and context from earlier traits in lexical trait-reference
order. Results are `{kind="pass"}`, `{kind="add_context",text=...}`,
`{kind="change",input=...}` for tool.before, `{kind="change",output=...}` for
tool.after, or `{kind="deny",reason=...}`. Native session and prompt changes
use `text`. Denial refuses the operation with the reason the agent sees.
The driver must advertise the result; Claude and Codex prompt hooks add context
or refuse prompts, while Codex input changes support shell commands only.
Transport semantics are verified against Claude 2.1.296, Codex 0.160.1,
Muse 1.4.4, Grok 1.0.30, and Agy's installed embedded hook contract.
Agy adds prompt context through `PreInvocation.injectSteps`; its tool hooks deny
or overwrite top-level argument fields. Changes cannot remove existing fields.
Its session-start and tool-after points are unsupported. Muse's verified tool
hooks add context, rewrite input or deny before execution; after execution they
add context only. Its session-start and prompt points remain unverified and
refuse activation. Grok tool hooks add context, rewrite input, deny execution,
or replace output after execution. Its prompt hook refuses typed prompts but
cannot add context; auto-wake and subagent prompts are observation-only. Grok
ignores session-start replies. Each refusal and restriction appears in the
Sessions catalog capability reason.
Claude validates rewritten tool inputs and output shapes and protects some
tools from replacement. Codex does not support tool output replacement.
Mandatory host authorization still applies to changed tool calls.

When tool.after replaces output, the host retains the original under the
trait's consent and returns a `bh:` record reference in `original_refs`.
The replacing app can keep `"bh:" .. turn.invocation_id` in its own index;
that reference becomes readable after the host accepts the replacement.
The approval card states this retention. The approved app reads it through
`bee.threads:authority.hook_original({record_ref=ref})`; revocation ends access.
Every invocation and accepted result rechecks active selection and live consent.
Crashes, invalid or oversized replies, and exhausted supervisor budgets record
diagnostics and act as pass. The host invocation owner supervises the app's
async future, cancels it on budget expiry or owner cancellation, and fences replies
by invocation ID. Elapsed limits use monotonic time. The host declares 2 seconds
per invocation and 8 seconds per chain in its hook budget entry; CLI chain limits
also use the driver's configured transport timeout: 3 seconds for command hooks,
2 seconds for Claude HTTP and Codex MCP hooks. Limits also include 16 invocations,
16 KiB per reply, 24 KiB accumulated context, and 128 KiB per turn and retained
original. Concurrent occurrence replays read the durable terminal decision;
a pending occurrence waits or is refused, and never counts as pass. Native tool input and replacement output also fit
its 8192-byte and 3000-byte boundaries. Cancelled and late replies cannot alter
an invocation that has ended.
