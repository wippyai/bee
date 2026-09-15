# Managed autoresearch

Bee can compose a small autoresearch assistant from existing managed Agent and
thread contracts. It does not need a second scheduler or Agent-to-Agent
transport.

The coordinator creates one durable thread, then starts the hidden
`bee.driver.codex:research_batch` and `bee.driver.claude:research_batch`
definitions with distinct request IDs and that same thread ID. Each start owns a
separate action and attempt. Carrier output, hooks and settlement enter the
thread in owner order, so the coordinator can consume them with an ordinary
durable subscription and resume that subscription after restart.

The application needs no private orchestration API. Its entire loop is:

1. `bee.threads.service:create` once for the research thread.
2. `bee.harness.launch:start` once per bounded research brief, with a stable
   request ID and the shared thread ID.
3. `bee.threads.delivery:subscribe`, `page` and `ack_page` to consume results.
4. `unsubscribe` on shutdown and `resume` with the retained subscription ID on
   the next application process.

An application policy allows only the launch and thread operations. The host
decides which driver-owned definitions are installed and active. Adding another
provider means installing its batch definition; it does not change the
coordinator.

Both batch routes are component-owned and host-selected. Codex runs with its
read-only sandbox. Claude is bounded to one turn. Their host policies may admit
the thread tools and the caller-owned `workspace` tool. Before Bee acquires a
session, project grant or credential projection, launch admission checks that
the requester is an active member of a supplied thread. The carrier checks
membership again when it commits output.

The coordinator can turn findings into an application candidate without
gaining activation authority:

1. Create a Governance authoring workspace with `workspace`.
2. Write findings or other source files with revision checks and stable retry
   keys.
3. Write `entries.json` as a JSON list of complete registry entries.
4. Freeze the workspace. Its returned digest identifies the exact file set.
5. Ask Modules to prepare that snapshot for the configured application. The
   destination converts `entries.json` to canonical
   `bee.governance-artifact@1` bytes without executing it.
6. Review, select, approve and apply through App Delivery.

The Agent scope has no registry publication, approval, overlay or activation
operation. A changed write needs a new retry key; a repeated launch request does
not create another action. Applying the candidate remains a separate local
human decision.

Current acceptance proves two managed launch actions settle into one shared
thread with distinct action/attempt identities and no duplicate receipt on
replay. A separate declaration check proves the shipped Codex and Claude batch
routes select their bounded policies, credentials, caller thread and workspace
tool. A durable coordinator subscription consumes both receipts, detaches,
resumes with a fresh lease and sees no duplicate work. The real HTTP/MCP fixture
proves one authenticated Agent actor can create, edit and freeze its workspace
while another actor cannot read it. Provider-backed execution of the shipped
routes, multi-Agent result quality and a dedicated coordinator UI remain
separate product acceptance.
