# Build a Bee app

Use this path from an agent connected to Bee. You need the existing `docs`,
`overlay`, `delivery` and `tests` MCP tools in your session. Bee keeps the app
private to your workspace until you request delivery and the person approves.

1. **Scaffold.** Read `reference_apps/starter` with `docs` (`operation: read`).
   It contains a complete `entries.json`: an app, a small library and its tests.
   Choose a lowercase overlay name such as `hello`. Replace every `app.hello`
   prefix when you rename it, including imports and test IDs. Keep the UI under
   `app.<name>.app`, one `process.lua` app, its Apps menu, and `restart_policy:
   never` for a view without checkpoints. To add access, list
   `{capability, parameters, reason}` items in the app entry's
   `meta.application.capabilities`; `docs/app_capabilities` lists exact
   requests, grants, risk classes and the errors preflight names. Registry
   access has no app capability; the agent's `components` tool reads installed
   components instead.
2. **Write tests.** Keep behaviour in a library and test it through the starter's
   `function.lua` test. Include the test in the same complete `entries.json`.
   Bee's tests tool runs installed apps: author tests before delivery and run
   them after approval.
3. **Freeze and preflight.** Call `overlay` with `operation: create`,
   `overlay_id`, `expected_revision: 0` and a stable `idempotency_key`. Put the
   complete JSON array at `entries.json` with `operation: put` and the returned
   revision; then `operation: freeze` with the next revision. Keep the returned
   `digest` as your `snapshot_digest`. Call `delivery` with `operation:
   preflight`, `source_overlay_id`, `version` and that exact `snapshot_digest`.
   Workspace defaults to the session's own workspace. Preflight checks the
   destination's modules, capabilities, protected definitions and policies,
   without staging a plan or asking for approval. Continue only when `ready`
   is true. Each diagnostic names the attempted change, the cause and a next
   step. Fix the source, put and freeze again, then preflight the new digest.
4. **Deliver.** Call `delivery` with `operation: request`, the same overlay,
   version and checked `snapshot_digest`. Read `ready` and any diagnostics or
   `activation_refusal`. A changed destination is checked again; a successful
   earlier check does not bypass current policy. Keep the returned `intent_id`
   and `approval_id`. Stop when it waits for the person; never approve yourself.
5. **Approve and verify.** The person approves this exact version and its
   permissions in **Needs you**. Read `delivery` with `operation: status`,
   `source_overlay_id`, `version` and `intent_id` until activation settles with
   `outcome: applied`. Bee opens the installed app on the desktops the person
   shows for the workspace; start it again yourself with `application_open`
   ([agents and apps](docs/agents_and_apps)). Use `tests` with `operation:
   list` and `application: app.<name>.app:app`, then `operation: run` for that
   application, then `operation: status` with its `run_id` until complete.
   Read the actual case results and totals; fix failures with a new version.

Writes always carry the current revision and a stable key for that one operation.
Do not reuse a delivered version for different bytes. A capability declaration
requests review; it is never a grant. Use [application contracts](docs/application_contracts)
for lifecycle details and [app capability catalog](docs/app_capabilities) for access.
