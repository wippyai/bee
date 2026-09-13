# Agy command hooks — integration evidence

Managed Agy currently delivers scoped MCP and appended profile guidance, but
refuses hook configuration. No command-hook sender is installed in Bee yet.
The existing carrier commits observations and publishes fixed activity labels;
it does not need an Agy-specific title process.

## Live CLI acceptance

On September 13, local Agy 1.2.2 completed two authenticated, bounded probes
using a disposable project and private HOME with one copied login file. Neither
probe used permission bypass flags, the user's settings, or project hooks.
The probes retained only hook event names, payload key names and a boolean
indicating conversation identity presence; login copies were removed afterward.

- A no-tools turn returned the requested `OK`, status `SUCCESS`, and observed
  `PreInvocation`, `PostInvocation` and `Stop`.
- A read-only task returned the exact fixture-file contents, status `SUCCESS`,
  and observed `PreToolUse`, `PostToolUse` and `Stop`.

Every command handler consumed its JSON stdin, wrote **nothing to stdout**, and
exited zero. Empty-output observation therefore works for these tested events;
Bee must not synthesize an `allow` permission decision merely to report activity.
This does not prove denied-tool behavior or gateway delivery from the real CLI.

Configuration was the private `.gemini/config/hooks.json` file. Tool events used
`{matcher: "", hooks: [handler]}` entries; the other events used flat handler
entries. Handlers were `type: command` with a two-second timeout. Tool payloads
included `conversationId`, `stepIdx` and `toolCall`; Stop included `executionNum`,
`terminationReason` and `fullyIdle`. Invocation payloads included `invocationNum`
and `initialNumSteps`. No synthetic event-name or session-start field was added.

Evidence outside the repository:
`bee-evidence/0912/agy-command-hook-live-probe.log` and
`agy-command-tool-hook-live-probe.log`. These are actual provider probes,
separate from the existing fixture-based managed-Agent acceptance.

## Remaining implementation

The first supported set should be `PreToolUse`, `PostToolUse` and `Stop`, which
already exist in the gateway event catalog. Invocation events must not be renamed
to prompt submission or successful completion. Driver decoding must preserve
missing occurrence identity as ambiguous; `stepIdx` alone is not a proven stable
tool-use identity. Hook observation never establishes a logical successful turn.

A command sender must use the existing authenticated hook endpoint with bounded
stdin, request lifetime and response handling. It must emit no gateway response
body as a harness decision, keep credentials out of argv and diagnostics, and
avoid starting a desktop or opening workspace databases for each hook. Executable
selection belongs to the host. It must not depend on a POC, curl/jq scripts,
or an added runtime ingress API.

Before enabling the host policy, acceptance still needs actual command delivery
through Bee, malformed/oversize payload refusal, revoked credentials, unavailable
gateway and cancellation, followed by committed thread observations and native
title updates. The empty-output probe is a prerequisite, not completed managed
Agy hook integration.
