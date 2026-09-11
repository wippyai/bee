# bee.placement

The placement contract and its values. A placement runs one admitted launch
as one attempt: it validates an owner's admitted request, records intent
before anything external exists, starts the child inside a runner it owns,
proves every transition with evidence, and removes the attempt's private
home only after the process is proven gone. Implementations
(`bee.placement.native`, later `bee.placement.docker`) own executors,
directories and receipts; this module owns none of them.

| Slice | Responsibility |
|---|---|
| `bee.placement` | `types`: request, grant, attempt, evidence and capability values; `request`: exact decoding and canonical digest; `transitions`: the execution and cleanup state machines; contract `placement` |

## Rules

- A `LaunchRequest` names the owner and its incarnation, the action and
  attempt, the exact binding and profile measurements, the host launch
  policy (`policy_ref`, a `bee.launch_policy` entry that alone selects a
  configuration's provider), the driver's declarative launch, resource
  grants by the owner's `grant_ref`, nonsecret environment values and
  host-resolved references, an optional retained `session_ref`, and the
  cleanup capability the launch requires.
- `measure_executable` measures one absolute host path read-only
  (`bee.executable-measurement@1`: content sha256, kind, interpreter line,
  size). A request may carry the plan's `executable` measurement; the runner
  measures again immediately before exec and refuses a change
  (`executable.changed`), recording `executable.measured` otherwise. The
  window between that measurement and the exec is the runtime's.
- A launch may declare `session_end: stdin_close`: the harness ends when
  stdin closes, and the owner asks `close_stdin` once the turn is decided.
  The runner closes it and answers, recording `stdin.closed` or
  `stdin.uncertain` apart from input acceptance and exit; stop and cleanup
  keep signal and cleanup authority.
- `prepare` fails closed when the runtime cannot provide `required_cleanup`;
  nothing is materialized first.
- Execution state (`intended`, `starting`, `running`, `stopping`, `exited`,
  `uncertain`) and cleanup state (`pending`, `complete`, `uncertain`) are
  separate. Cleanup runs only from `exited`. A process-group absence proof
  requires a successful, fully decoded process-table query; command failure,
  malformed output and an empty result retain uncertainty. A failed signal
  probe is never evidence that the group is gone.
- Signal evidence is not exit evidence. A liveness observation is returned
  beside the recorded state, never folded into it.
- Capabilities: `direct_process` controls the launched pid only,
  `process_group` controls what remains in the created group, and
  `contained_tree` needs a stronger boundary than a process group. A
  descendant that starts its own session escapes a group.

`make identity-native-check` loads the production identity library in a minimal
native host. It verifies a live group, the same group after its leader is killed
and reaped, and failed, malformed and empty process-table responses. These
observations prove the absence check; they do not establish managed-terminal
identity transfer or process-tree containment.
