# Bee external executor

The external executor handles one pulled turn with one admitted CLI launch.
It calls the selected driver's `prepare` for the first turn and `dispatch` with
the stored opaque resume identity on later turns. Native placement persists the
launch intent before start and owns process observation, reconciliation and
cleanup. A turn is settled only after the driver normalizer reports a terminal
result and placement proves the process exited. The returned driver
checkpoint is ready for the authenticated Sessions worker to commit. Missing
terminal or exit proof is uncertain.

The driver's launch and normalization operations define prompts,
resume identity, events and usage. Each turn uses the launch defined by the selected
driver contract. When the descriptor declares an answer transport, the shared
Harness permission exchange sends durable Allow/Deny decisions to the waiting
CLI. A terminal result closes stdin when the launch selects `stdin_close`,
after pending permission responses are acknowledged. The executor records the
closure intent before calling placement and still waits for process exit.

Each attempt records progress before prepare, gateway admission and CLI start.
Normalized assistant text, tool events and usage are appended live through the
fenced Threads observation operation. Caller identity comes from the canonical
Session route, under host-selected admission policies.
