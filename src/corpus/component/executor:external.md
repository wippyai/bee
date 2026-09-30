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
resume identity, events and usage. The executor does not write to a live
CLI session; each turn uses only the launch defined by the selected
driver contract.
