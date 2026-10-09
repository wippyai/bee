# Build an app that listens to a session

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
stored input and result. Process the page durably, then acknowledge its exact
identity and extent. An empty filtered page can still advance through unrelated
records: acknowledge it when it has a `page_id`. Outstanding pages replay until
acknowledged. The host owns the consumer identity, cursor and durability, so a
restarted app uses the same subscription. `resume` reattaches after an owner
restart or reactivation. Every page and acknowledgement rechecks consent.

Selection starts after the committed sequence at approval. Delivery excludes
other sessions on the thread and inactive intervals. Revocation invalidates
outstanding pages. Listening grants no thread membership; an app stores its own
index and uses its separately authorized Threads access for reading it.
