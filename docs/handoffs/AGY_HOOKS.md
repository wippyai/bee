# Agy command hooks — integration evidence

Installed Agy delivers scoped MCP and appended profile guidance, but refuses
hook configuration. Follow-up source now renders its window command hooks and
decodes their wire fields. Focused native race tests/vet, packaged acceptance,
offline boot and actual managed-provider gateway delivery now pass. No command-hook sender is installed globally yet.
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

## Source integration and remaining acceptance

The host policy selects `hook_command_ref`, an env.variable reference. The
carrier and placement independently resolve it and include the absolute path in
the measured driver configuration as `gateway.hook_command`. Agy receives no
authority to select its own executable. The declared variable uses the native
host's `self` fact so the helper matches the running Bee binary, even while a
different global executable is installed. Policies without a command helper keep
their previous configuration measurements.

Source tests verify command-file shape, separate token environment, host-command
measurement, missing helper refusal, malformed and mixed wire-schema refusal,
content hashing and ambiguous occurrence handling. All 841 Lua tests pass. The
native selector fixture now invokes the rendered command and checks committed
observations and their conservative `Activity uncertain` title, and passes against assembled candidate `8fdc0b37` with native `fe8cb0d`.

The selected window set is `PreToolUse`, `PostToolUse` and `Stop`, which
already exist in the gateway event catalog. Invocation events must not be renamed
to prompt submission or successful completion. Driver decoding must preserve
missing occurrence identity as ambiguous; `stepIdx` alone is not a proven stable
tool-use identity. Hook observation never establishes a logical successful turn.

A command sender uses the existing authenticated hook endpoint with bounded
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

Native `938192c` supplies the command and `self` fact, based on the previously
pinned native `0f63d30`. Its hook, host-environment and desktop-routing race tests
and vet pass against the reviewed runtime. Source pins that native revision; no
runtime PR or runtime semantic change was needed. Evidence is
`bee-evidence/0912/native-hook-post-check.log`. The first stalled-peer test hung
in HTTP test-server teardown, independently of the sender deadline; teardown now
has its own release path, and a real OS-pipe cancellation case also passes.

The first assembled candidate passed offline boot but failed the managed Agy
fixture: the command sender rejected Bee's real `action:` ID prefix. Native
`fe8cb0d` permits the colon in that bounded path segment and tests an actual
`action:request-1` POST. Focused race tests and vet pass
(`native-hook-post-action-id-check.log`). Source now pins this correction;
final assembled acceptance remains pending. The failed candidate was not installed.

Corrected candidate `8fdc0b37` (source `0d92979`, native `fe8cb0d`) passes
`make native-binary-check`, including all four managed profiles with and without
machine login. The Agy fixture executes the generated command through the real
packaged sender, gateway and thread store and checks the conservative title.
`make offline-boot-check` also passes fresh boot, restart and retained-client
reconnect with only loopback available (0.104 s warm reconnect). Evidence:
`agy-hooks-final-native-binary-check.log` and
`agy-hooks-final-offline-boot-check.log`. Full source regression remains running;
this candidate is not yet installed. Real-provider managed gateway delivery is
still distinct from both these fixture checks and the earlier live CLI probes.

## Live managed gateway acceptance

The corrected exact candidate also passes an authenticated Agy 1.2.2 run launched
through Bee's native Agent picker. The disposable project supplied one read-only
fixture file; Bee generated the private session HOME, scoped MCP configuration
and command hooks. The actual Agy executable ran a bounded print-mode read task
inside that managed terminal, without permission bypass flags. It returned
`SUCCESS` and the exact fixture text. Read-only inspection of Bee's thread store
confirmed committed `PreToolUse`, `PostToolUse` and `Stop` observations with a
nonempty conversation identity and no invented stable tool occurrence ID.

The probe used a sanitized environment and copied only the machine login into a
private fixture HOME; all fixture homes and copied credentials were removed.
Provider output and credentials were not printed to evidence. Log:
`bee-evidence/0912/agy-live-managed-gateway.log` (session `85239`, exit 0).
This closes managed command-hook delivery for the tested read task. It does not
prove real-provider cold recovery, denied-tool behavior, or interactive prompt
and permission handling across reconnects.

## Discovered real-provider MCP gap

Follow-up actual-provider MCP acceptance failed: Agy reported `SUCCESS` but
returned an empty response, and no requested thread message committed. A bounded
loopback MCP-server probe then captured the authentication behavior using only
a dummy credential. Agy 1.2.2 sends both `${BEE_TEST_TOKEN}` and
`${env:BEE_TEST_TOKEN}` literally in the Authorization header; neither form is
expanded. Its real initialize and tools/list requests reached the probe with the
literal value. Bee's current Agy renderer therefore does not authenticate MCP.

The existing native selector fixture masks this by explicitly resolving Agy's
placeholder from the child environment in `mcpProbeConfig`. Its passing MCP gate
proves the Bee endpoint with a fixture client, not real Agy authentication. The
actual managed hook proof above remains valid: command hooks read their own
credential environment through the packaged sender independently of MCP.

Evidence: `agy-live-managed-mcp.log`, `agy-live-managed-mcp-diagnostic.log`,
`agy-mcp-header-expansion.log`, `agy-mcp-header-env-expansion.log` under
`bee-evidence/0912`. The official MCP documentation describes literal custom
headers, matching the observed behavior: <https://antigravity.google/docs/mcp>.
It also states that unconfigured MCP tools default to Ask. Tool permission
behavior must be checked after correcting credential delivery; observation hooks
must not synthesize an approval to make this pass.

Correct the driver/placement credential delivery without putting token bytes in
admission records, measured templates, argv or diagnostics, or weakening gateway
authorization. Update the fixture to model actual Agy header behavior as part of
that fix, then repeat live managed MCP acceptance. The candidate remains
uninstalled while this integration gap is resolved.

The follow-up source uses `bee.agy-mcp@2`: the JSON template has an empty
Authorization value and a typed `secret_fields` declaration naming its object
key path, admitted environment destination and `Bearer ` prefix. Driver
configuration admission refuses fields for any unselected credential. Native
placement independently checks the gateway selection, mints the token, encodes
it into that field and writes through protected creation only after verifying
the placement root excludes group/other access. Stored delivery templates,
request digests, receipts and arguments contain no token bytes. Nonempty targets,
missing credentials and oversized final encoding refuse materialization.
The gateway's existing retirement path owns any failure after token minting.

This is an optional JSON configuration field feature, not a token-expanding
proxy or a runtime change. Other driver configurations remain unchanged. Retained
configuration still permits only identical content; this does not introduce
unsafe replacement or claim Agy cold recovery. Source validation and a rebuilt
real-provider MCP proof are required before installation.

Validation checkpoint: production lint passes; focused Agy/configuration tests
pass all 31 cases. The broad unit run passed 843 cases and failed only the old
`bee.agy-mcp@1` expectation; the corrected expectation is included in the focused
passing run. Native fixture Go tests/vet pass. A fresh full check and assembled
candidate are next. The earlier hook-only source full `make check` also completed
successfully (session `75977`, exit 0).

Corrected candidate `9b499f4e` (production `01ed3e3`, native `fe8cb0d`) passes
native executable acceptance and offline boot/restart/reconnect (0.105 s warm).
The native Agy fixture now sends the literal materialized header, authenticates
MCP and verifies its token is absent from recorded placement requests/evidence.
All 844 unit cases pass in the new full regression; later gates are still running.

Actual Agy 1.2.2 also completes the corrected managed MCP task. Default print mode
could not execute the tools; the follow-up disposable session explicitly allowed
only `mcp(bee/thread_read)` and `mcp(bee/thread_message)` using Agy's documented
permissions file. No bypass flag or wildcard permission was used. The provider
returned `SUCCESS` and the exact requested completion text; independent read-only
inspection found exactly one expected message in the bound thread and a committed
Stop observation. The fixture homes and copied login were removed. This proves
actual scoped MCP delivery with those explicit permission choices, not automatic
approval in production or real-provider recovery. Production retains Agy's normal
permission prompts. Evidence: `agy-live-managed-mcp-allowed.log` (session `22796`,
exit 0), `agy-mcp-native-check.log` (`43706`, exit 0),
`agy-mcp-offline-check.log` (`88196`, exit 0), and `agy-mcp-full-check.log`
(still running as `94825`). The candidate is not installed yet.
