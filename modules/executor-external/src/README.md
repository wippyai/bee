# Bee external executor

The external executor handles one pulled turn with one admitted CLI launch.
It calls the provider's `prepare` for the first turn and `dispatch` with the
stored provider resume identity on later turns. Native placement persists the
launch intent before start and owns process observation, reconciliation and
cleanup. A turn is settled only after the provider codec reports a terminal
result and placement proves the process exited. The returned provider
checkpoint is ready for the authenticated Sessions worker to commit. Missing
terminal or exit proof is uncertain.

The initial adapters are Claude Code and Codex CLI. Their existing launch and
normalization codecs define prompts, resume identity, events and usage. The
executor does not write to a live provider session; Codex's initial prompt
uses the launch's admitted stdin input.
