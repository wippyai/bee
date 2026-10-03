# Production Lua timer audit

Baseline: `7ea144157902f060cb16f6e8f9f734432938bfda` (origin/main when this lane began).
Scope: production Lua in `src/` and every `modules/*/src` tree. Tests, native Go,
upstream runtime/network implementation and applied migration SQL are outside this
110-site constructor inventory: 72 `after`, 14 `timer`, 21 `ticker`, 3 `sleep`.
Classification is of each original call site; a shared scheduler may also serve
several semantic bounds listed below. Initial unarmed runner timers are included.

(a) is a declared protocol/caller bound or periodic tick; (b) infers an outcome
from elapsed time despite observable work; (c) masks expiry by retiring work or
changing to success/a weaker state. Remaining b/c startup sites are assigned to
the coordinated Docker start lane, not claimed as fixes in this branch.

Constructor counts: (a) 60, (b) 42, (c) 8.

| Baseline source:line | Timer | Class | Disposition | Reason |
|---|---|---|---|---|
| `src/apps/broker.lua:1073` | `ticker` | a | retained or replaced by events | Periodic admission refresh; the tick reads registry state and never decides completion. |
| `src/apps/broker.lua:1097` | `timer` | b | fixed | Shared deadline scheduler formerly included guessed startup/checkpoint/drain bounds; retained for declared stop grace and retry scheduling only. |
| `src/apps/execution.lua:62` | `after` | a | retained or replaced by events | Declared cooperative stop grace; expiry logs the bound and escalates, then awaits monitored EXIT. |
| `src/apps/open_method.lua:97` | `timer` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/client/main.lua:48` | `ticker` | a | retained or replaced by events | Periodic node-default refresh; a tick never cancels an in-flight read. |
| `src/client/main.lua:136` | `after` | c | fixed | Expiry retires live work or changes presentation/availability to a weaker state before its reply. |
| `src/client/main.lua:346` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/client/main.lua:462` | `after` | c | fixed | Expiry retires live work or changes presentation/availability to a weaker state before its reply. |
| `src/client/main.lua:622` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/hive/desktop/display.lua:67` | `after` | b | fixed | Lifetime registration waits for its exact acknowledgement, supervisor EXIT or cancellation. |
| `src/hive/supervisor/main.lua:109` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `src/host/main.lua:356` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/host/main.lua:387` | `timer` | c | fixed | Expiry retires live work or changes presentation/availability to a weaker state before its reply. |
| `src/host/main.lua:425` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/launch/bootstrap.lua:41` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/launch/daemon.lua:33` | `after` | a | retained or replaced by events | Registration polling cadence; service state or lifecycle cancellation decides readiness. |
| `src/launch/desktop_lifecycle.lua:63` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/launch/desktop_lifecycle.lua:124` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/launch/desktop_lifecycle.lua:139` | `after` | c | fixed | Expiry retires live work or changes presentation/availability to a weaker state before its reply. |
| `src/launch/desktop_lifecycle.lua:194` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/launch/desktop_lifecycle.lua:264` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/launch/desktop_lifecycle.lua:287` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/launch/desktop_lifecycle.lua:317` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/launch/desktop_storage.lua:71` | `after` | c | fixed | Expiry retires live work or changes presentation/availability to a weaker state before its reply. |
| `src/launch/headless.lua:24` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `src/launch/host_manager.lua:222` | `timer` | a | retained or replaced by events | Declared idle-host lease grace; expiry requests a stop after the last lease ends. |
| `src/launch/owner.lua:45` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `src/launch/owner.lua:141` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `src/launch/owner.lua:144` | `ticker` | a | retained or replaced by events | Periodic startup-failure observation; elapsed time does not declare startup stalled. |
| `src/launch/supervisor.lua:68` | `after` | a | retained or replaced by events | Declared best-effort failure-report acknowledgement bound=1s; expiry is logged with the original failure. |
| `src/launch/supervisor.lua:153` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `src/launch/supervisor.lua:157` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `src/launch/supervisor.lua:324` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `src/launch/supervisor.lua:333` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `src/launch/supervisor.lua:356` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `src/terminal/main.lua:61` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `src/terminal/main.lua:274` | `timer` | a | retained or replaced by events | Declared input/render scheduling cadence; expiry never retires a clipboard request or PTY process. |
| `modules/approvals-inbox/src/app/app.lua:107` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/approvals/src/service/worker.lua:46` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/gateway/src/service/publication_worker.lua:31` | `after` | a | retained or replaced by events | Declared worker retry or refresh cadence; work results come from the operation, not elapsed time. |
| `modules/gateway/src/service/worker.lua:31` | `after` | a | retained or replaced by events | Declared worker retry or refresh cadence; work results come from the operation, not elapsed time. |
| `modules/settings/src/app/app.lua:59` | `timer` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `modules/threads/src/delivery/waits.lua:153` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `modules/threads/src/delivery/waits.lua:181` | `after` | a | retained or replaced by events | Caller-selected watch wait_ms/transport budget; final authoritative record check reports timeout. |
| `modules/threads/src/delivery/waits.lua:240` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `modules/threads/src/delivery/waits.lua:270` | `after` | a | retained or replaced by events | Caller-selected delivery wait_ms/transport budget; final authoritative record check reports timeout. |
| `modules/threads/src/service/owner.lua:31` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/threads/src/service/pump_worker.lua:62` | `after` | a | retained or replaced by events | Declared worker retry or refresh cadence; work results come from the operation, not elapsed time. |
| `modules/threads/src/service/waiter.lua:31` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/application/src/host_leases.lua:219` | `timer` | a | retained or replaced by events | Caller-selected holdings read timeout; expiry names that bound and the read operation. |
| `modules/application/src/host_leases.lua:264` | `timer` | a | retained or replaced by events | Explicit acquire API observation timeout; expiry names the bound and requests lease release, never claims acquisition. |
| `modules/application/src/host_leases.lua:305` | `timer` | a | retained or replaced by events | Explicit attach API observation timeout; expiry names the bound and reports attachment remains unknown. |
| `modules/driver/src/locate/probe_capture.lua:74` | `after` | a | retained or replaced by events | Caller-selected host-probe timeout_ms; expiry closes the probe and names the exact bound. |
| `modules/sessions/src/binding/lifecycle.lua:17` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `modules/sessions/src/binding/lifecycle.lua:19` | `after` | a | retained or replaced by events | Scheduler-registration polling cadence; readiness and lifecycle cancellation decide the wait. |
| `modules/sessions/src/binding/lifecycle.lua:40` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `modules/sessions/src/service/scheduler_worker.lua:55` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/harness/src/app/picker.lua:79` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/harness/src/app/picker.lua:354` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/harness/src/app/runtime.lua:180` | `timer` | c | fixed | Expiry retires live work or changes presentation/availability to a weaker state before its reply. |
| `modules/harness/src/app/runtime.lua:835` | `timer` | c | fixed | Expiry retires live work or changes presentation/availability to a weaker state before its reply. |
| `modules/harness/src/carrier/interrupted.lua:104` | `timer` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `modules/harness/src/launch/managed_run.lua:371` | `sleep` | a | retained or replaced by events | Retry cadence inside caller-selected cancellation wait_ms; expiry reports DEADLINE_EXCEEDED with recorded state. |
| `modules/harness/src/service/presentation.lua:34` | `timer` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `modules/harness/src/service/process.lua:65` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/harness/src/service/process.lua:108` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/harness/src/service/process.lua:116` | `after` | a | retained or replaced by events | Initially unarmed drain timer; it is excluded from selection until an observed exit arms the declared drain. |
| `modules/harness/src/service/process.lua:121` | `after` | a | retained or replaced by events | Declared post-exit runner/delivery drain; expiry records the bound and incomplete delivery. |
| `modules/harness/src/service/process.lua:140` | `after` | b | fixed | Carrier wait expiry substitutes for runner EXIT; runner already owns stop escalation. |
| `modules/harness/src/service/process.lua:233` | `after` | a | retained or replaced by events | Declared carrier drain_ms after runner EXIT; expiry preserves incomplete output. |
| `modules/placement-docker/src/service/environment.lua:86` | `after` | b | coordinated; unmodified | Environment/listener/image preparation startup guess; coordinated Docker start lane, unmodified here. |
| `modules/placement-docker/src/service/environment.lua:91` | `after` | a | retained or replaced by events | Startup readiness polling cadence; the surrounding guessed start deadline belongs to the coordinated Docker lane. |
| `modules/placement-docker/src/service/environment.lua:130` | `after` | b | coordinated; unmodified | Environment/listener/image preparation startup guess; coordinated Docker start lane, unmodified here. |
| `modules/placement-docker/src/service/environment.lua:136` | `after` | a | retained or replaced by events | Startup readiness polling cadence; the surrounding guessed start deadline belongs to the coordinated Docker lane. |
| `modules/placement-docker/src/service/environment.lua:196` | `after` | b | coordinated; unmodified | Environment/listener/image preparation startup guess; coordinated Docker start lane, unmodified here. |
| `modules/placement-docker/src/service/environment.lua:201` | `after` | a | retained or replaced by events | Startup readiness polling cadence; the surrounding guessed start deadline belongs to the coordinated Docker lane. |
| `modules/placement-docker/src/service/image.lua:317` | `after` | b | coordinated; unmodified | Environment/listener/image preparation startup guess; coordinated Docker start lane, unmodified here. |
| `modules/placement-docker/src/service/sweeper.lua:10` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/desktop/src/service/main.lua:129` | `timer` | c | fixed | Expiry retires live work or changes presentation/availability to a weaker state before its reply. |
| `modules/host-processes/src/app/app.lua:27` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/hive/src/binding/client.lua:69` | `after` | a | retained or replaced by events | Explicit network-call timeout; DEADLINE_EXCEEDED names the selected duration and unknown dispatch outcome. |
| `modules/executor-external/src/binding/answer_hook.lua:190` | `sleep` | a | retained or replaced by events | Long-poll slice while awaiting an approval; expiry only rechecks the authoritative owner. |
| `modules/executor-external/src/binding/run_turn.lua:92` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/executor-external/src/binding/run_turn.lua:114` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/executor-external/src/binding/run_turn.lua:118` | `after` | a | retained or replaced by events | Caller-selected wall_time_ms budget; expiry requests stop and requires typed placement exit evidence. |
| `modules/executor-external/src/binding/run_turn.lua:400` | `after` | a | retained or replaced by events | Remaining caller-selected wall_time_ms budget; expiry requests stop and requires typed placement exit evidence. |
| `modules/sync/src/service/distribution_worker.lua:11` | `after` | a | retained or replaced by events | Declared worker retry or refresh cadence; work results come from the operation, not elapsed time. |
| `modules/hive-manager/src/app/app.lua:102` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `modules/hive-manager/src/app/app.lua:143` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/persist/src/persist/transaction.lua:73` | `sleep` | a | retained or replaced by events | Declared SQL contention retry backoff; exhausted transaction attempts return the database error. |
| `modules/threads-timeline/src/app/app.lua:54` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/placement-native/src/service/runner.lua:291` | `after` | a | retained or replaced by events | Initially unarmed output-coalescing timer, excluded from selection until batching starts. |
| `modules/placement-native/src/service/runner.lua:314` | `after` | a | retained or replaced by events | Declared output batch coalescing window; expiry flushes the batch without inferring process outcome. |
| `modules/placement-native/src/service/runner.lua:322` | `after` | a | retained or replaced by events | Initially unarmed stop-grace timer; excluded until an explicit stop. |
| `modules/placement-native/src/service/runner.lua:327` | `after` | a | retained or replaced by events | Initially unarmed output-retention timer; excluded until post-exit retention starts. |
| `modules/placement-native/src/service/runner.lua:333` | `after` | a | retained or replaced by events | Initially unarmed pipe-drain timer; excluded until native exit evidence. |
| `modules/placement-native/src/service/runner.lua:340` | `after` | a | retained or replaced by events | Initially unarmed carrier-takeover timer; excluded until monitored carrier loss. |
| `modules/placement-native/src/service/runner.lua:393` | `after` | a | retained or replaced by events | Declared stop_grace_ms; expiry records the exact grace and escalates to kill. |
| `modules/placement-native/src/service/runner.lua:406` | `after` | a | retained or replaced by events | Declared post-exit drain_ms; expiry records forced stream truncation and the duration. |
| `modules/placement-native/src/service/runner.lua:616` | `after` | a | retained or replaced by events | Declared carrier takeover grace; expiry revokes only after observed carrier loss. |
| `modules/placement-native/src/service/runner.lua:629` | `after` | a | retained or replaced by events | Declared post-exit retain_ms; expiry records the duration and exact lost output. |
| `modules/placement-native/src/service/service.lua:613` | `after` | b | coordinated; unmodified | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `modules/placement-native/src/service/service.lua:766` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `modules/placement-native/src/service/service.lua:795` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `modules/placement-native/src/service/service.lua:1110` | `after` | b | fixed | Guessed startup, local acknowledgement or recovery deadline; replace with supervision/events. |
| `modules/placement-native/src/service/sweeper.lua:11` | `ticker` | a | retained or replaced by events | Periodic refresh or reconciliation tick; the owner reads authoritative state on each tick. |
| `modules/hub/src/binding/backend.lua:38` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `modules/hub/src/binding/backend.lua:114` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `modules/hub/src/binding/lifecycle.lua:91` | `after` | b | fixed | Local work/acknowledgement remains pending until readiness, correlated reply, supervised state, EXIT or lifecycle cancellation. |
| `modules/hub/src/binding/lifecycle.lua:96` | `after` | a | replaced by events | Periodic supervisor observation; now wakes on supervisor service.update events. |

## Arithmetic and delegated bounds

| Mechanism | Class | Implemented disposition |
|---|---|---|
| `src/apps/lifecycle.lua`: startup + negotiated-close reply deadlines | b (2) | Startup and close negotiation wait for ready, app/person decision, explicit stop or EXIT. Stop and termination grace remain a. |
| `src/apps/broker.lua`: checkpoint, cleanup, replacement drain, replacement-request elapsed budget | b (4) | Pending writes and instances are retained until acknowledgement/EXIT. Owner refusal is rechecked periodically without guessing failure. |
| `src/launch/daemon.lua`: startup progress arithmetic | b (1) | Read actual startup failure; periodic registry readiness observation and explicit cancellation. |
| `modules/application/src/status/startup_progress.lua`: inactivity deadline helper | b (1) | Deleted deadline arithmetic; only validated monotonic phase/revision values remain. |
| `modules/desktop/src/service/status.lua`: future timeout | c (1) | Future completion or binding/owner lifecycle retires it. |
| `src/client/node_appearance.lua`: local defaults future timeout | c (1) | Future completion or client shutdown retires it; the periodic refresh schedule never cancels live work. |
| `modules/harness/src/carrier/delivery.lua`: advance/complete future timeout | c (2) | Only completion and lifecycle cancellation retire the future. |
| `modules/harness/src/carrier/hooks.lua`: drain deadline | c (1) | Owner-confirmed seal/commit/ack completion ends drain. |
| `modules/harness/src/carrier/interrupted.lua`: recovery loop budget | b (1) | Native exit evidence and completed hook drain precede settlement. |
| `modules/harness/src/carrier/machine.lua`: hook-close drain budget | c (1) | Seal intake, drain until empty; return exact drain failure. |
| `modules/harness/src/app/runtime.lua`: checkpoint deadline | b (1) | Exact broker acknowledgement or lifecycle cancellation. |
| `modules/host-processes/src/app/stop_request.lua`: five refresh ticks | b (1) | Correlated broker stop result; app lifecycle cancellation remains explicit. |
| `modules/harness/src/launch/managed_run.lua`: caller `wait_ms` cancellation budget | c (1) | Kept caller observation bound; expiry reports duration and observed state; status/stop/wait errors propagate. |
| Native placement request `timeouts.start_ms`; carrier policy `start_ms` | b; coordinated | Start redesign lane owns these existing wire fields; not edited here. |
| Carrier runner output drain, retention, takeover, stop grace | a | After observed EXIT/stop, declared bounds name forced truncation, lost output, grant retirement or escalation; no timer proves completeness. |
| Thread wait/watch and Sessions await/join `wait_ms`/`timeout_ms` | a | Caller-selected observation ends with a final authoritative state/record check; it never cancels work. |
| Host lease idle grace, gateway drain, approvals/credential/grant/delegation expiry, delivery claim leases | a | Explicit lifecycle/authority lease bounds. Expiry revokes admission or retention; it does not infer work completion. |
| Hive call/assertion deadlines and peer hello validity | a | Declared wire/transport bounds with exact expiry faults; dispatched effects retain reconciliation responsibility. |
| SQL busy timeout and bounded transaction backoff | a | Database contention limit; exact database failure is returned, no commit is fabricated. |
| `hub.*`, HTTP readiness/governance, driver Wippy calls and provider hook timeouts | a | External network/provider response bounds. Underlying expiry errors propagate; local worker lifetimes no longer inherit guessed Hub deadlines. |
| Executor external wall-time/session budget and explicit `on_stall=cancel_work` quiet period | a | Caller-declared cancellation policy; names the exceeded budget and observes placement stop/terminal evidence. |

Additional arithmetic concepts: (a) 8 grouped protocol families, (b) 11 individual
guesses fixed, (c) 7 individual masks fixed; start fields are coordinated separately.
No persisted ID, topic, schema, applied migration or store layout changes.
Native startup watchdogs (`native/launch/startup.go` and owner-lease waits in
`native/launch/client.go`) are outside this Lua inventory and remain unchanged.
