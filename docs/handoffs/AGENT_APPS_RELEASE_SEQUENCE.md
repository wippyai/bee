# Agent applications release sequence — September 19

The destination is a usable Bee where managed agents, external workers, local
models and deterministic tools coordinate through profiles, scoped MCP, durable
threads and governed applications. Prove applications before adding more worker
types. `llm.transition` is a future component integration, not a current API.

Work one acceptance milestone at a time.

Bee is greenfield: keep one implementation and remove superseded paths rather
than adding compatibility layers. Verified Bee changes go directly to `main`;
runtime changes still use upstream pull requests.

1. **Application opening — complete in source and pack.** The explicitly admitted
   MCP operation uses the production gateway, workspace host and broker.
   Acceptance proves sender authorization, binding-selected workspace,
   conflict/refusal behavior, visible display assignment and restart recovery.
   A delayed-broker regression proves that caller expiry retains assignment
   responsibility and that unresolved retries do not redispatch. Concurrent
   callers are bounded and coalesced; simultaneous-caller fault injection is
   not a separate acceptance claim. This milestone is not a global release.
2. **Executable integration and global candidate.** After runtime PR #787 lands,
   integrate the prepared Bee Host/Plan port and update the runtime/build inputs.
   Run assembled native, offline startup, project isolation, recovery and pack
   isolation gates. Install only the verified candidate, retaining rollback.
3. **Agent identity in the UI.** Display definition and saved-profile identities
   and descriptions when selecting an agent. Retain the selected launch identity
   in durable records so the thread can show it after restart. Keep definition,
   saved profile, driver profile, action, attempt and thread identities distinct.
4. **Promptmap quality audit.** Scan components for duplicate ownership, unused
   code and unnecessary indirection. Verify findings, fix bounded groups and run
   their behavioral gates. Do not create speculative abstractions from scan
   suggestions.
5. **App modification and node synchronization.** Prove create, edit, version
   update and rollback across two real nodes. Replicated publication does not
   replace destination-local review and activation.
6. **Reference application.** Prove one complete agent-authored metrics app:
   the agent opens it, invokes its declared traits/tools to run a task and read
   measurements, and the user sees the same progress and metrics in its UI.
   Use scoped MCP and existing thread coordination, with little application
   glue and no separate agent-only state. This is an acceptance requirement,
   not a claim that live application tools are already complete. Finish this
   before adding further hybrid worker/model features.

Completed prerequisite: Bee PR #14 merged to `main` at `d97fd77`, with offline
docs, delivery, scoped child launch and Timeline fixes. Its recorded local suite
passed 1,106 tests; hosted jobs could not start because of GitHub billing.
Runtime PR #787 at `7f9e7e89bc` passes all hosted checks, including Windows after
the cache-repair fix, and is assigned to Rodrigo (`skhaz`) for review.

The global executable has not been updated by this sequence. Preserve the
unrelated `modules/bee-registry-planner/` work.

Current app-opening worktree checkpoint: `make app-journey-check` passes the
real MCP source and packed journeys, including presentation on the origin
display, replay/conflict, unauthorized sender and foreign-workspace refusal,
checkpoint and restart. Each composition is approved against its own exact
base; source approvals are not replayed onto a different packed base.
The combined unit run passes all 1,110 cases, including child launch origin
inheritance through real MCP and gateway migration 12. `make gateway-check`
and source/packed `make workspace-hosts-check` pass. Review found a late-reply
race after the 30-second caller deadline: the host now retains bounded
in-flight operations until broker settlement, so a late success still receives
its originating display assignment. The source/packed delayed-broker regression
passes with the production deadline unchanged. The final full-check run has
passed units, managed windows/hooks, module boundaries, gateway, packaging and
headless startup. The standalone Governance guide dependency, Hub canonicalizer
module declaration and Modules install-fixture lock were corrected; their
focused gates pass. The resumed check completes storage and all desktop gates,
including input, selection, recovery, inbox, governed delivery, Hive Manager and
Timeline. The full check coverage passes across the original and resumed runs.
Restoring the former discard-on-expiry behavior in a disposable composition
makes the delayed-broker regression fail with `retry redispatched unresolved open`.

The next release step remains the prepared executable integration after runtime
#787 merges. It is still open at `7f9e7e89bc`; no new runtime API or compatibility
path was introduced for application opening. Agent identity UI work is scoped:
project the existing definition/profile/thread/action/attempt identities and
bounded descriptions rather than introducing another identity model.
