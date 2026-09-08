# Local foundation acceptance

This records the delivered local-foundation goal and the remaining host/client
work. It is not a claim that Bee's proposed Hive, agent or installation APIs exist.

## Verified checkpoint

Production checkpoint `aaf3628` passed `make check` and rebuilt standalone binary
acceptance. Attachment-only checks were subsequently strengthened through
`c2e079b` and passed in source and pack. The work is synced on
`feat/independent-view-bindings`; GitHub rejected a direct main update because
main now requires a pull request and status checks. No PR was opened or merged.
Uncommitted native packaging work owned by another contributor is not certified
by this checkpoint.

| Goal requirement | Implementation and acceptance evidence |
|---|---|
| Settings and nostalgic themes | Standalone Settings provides DOS and Windows Classic among 16 themes, 11 backgrounds and tab appearance. `tests/tui_smoke.py`, `taskbar.py`, `personalization.py` and `console.py` exercise appearance, saved preferences and readable Classic terminal defaults. |
| Window behavior and prompt exit | Source/pack UI, navigation, drag failure, dialog and close-confirmation checks cover resize, fullscreen, minimize, focus, input isolation and presenter recovery. The 16-app lifecycle load check completed shutdown in about 335 ms at this checkpoint. Timings describe the test environment, not a universal latency guarantee. |
| Durable state and permissions | Storage, recovery and control-delivery checks cover migration integrity, stable workspace identity, stale-writer rejection, checkpoint receipts, cold recovery and interrupted core delivery. App scopes deny direct workspace SQL, registry mutation and foreign terminal access; native shells retain OS-user authority. |
| Thread/subscriber prototype | `make threads` tests the isolated native actor/contract prototype: bounded replay, cursor resume, live catch-up, authenticated denial, duplicate/conflicting appends and migration checks. This is distinct from production subscriptions. |
| Useful live test-status app | `tests/test_status.py` proves explicit launch arguments, actual shared-UI checks, completion after its view closes, reopen/cold replay, duplicate-run suppression and F12. Production views poll the local journal; durable scheduling and push subscriptions remain unimplemented. |
| Standalone processes and typed contracts | Registry/import audits and strict lint cover the composed source and pack. Each app is a process. The broker owns producer capabilities and lifecycle; the workspace owns recovery; the session owns layout; the presenter is replaceable. |
| Workspace/client design | `WORKSPACE_ATTACHMENTS.md` and `CLIENT_HOST_SPLIT.md` define qualified identities, host-selected admission, client layout ownership, controller/observer rights, migration receipts and native mesh routing. Current owner-only targeted binding and cross-actor observer tests prove prerequisites, not a complete client API. |
| Cluster disabled by default | Source configuration declares no cluster/membership profile. The Linux source/pack UI check inspects the running Bee process's socket inodes after boot and rejects TCP listeners or bound UDP endpoints. This verifies the default test composition, not user-supplied profiles or arbitrary native commands. |
| Accurate scope | Kickside compatibility, AI drivers, models, MCP, Hub activation and in-app self-update remain proposals. Command aliases launch installed native programs. Runtime cluster/Raft changes remain with their separate owner. |

## Launch

For the locally assembled development executable:

```sh
install -Dm755 dist/bee "$HOME/.local/bin/bee"
export PATH="$HOME/.local/bin:$PATH"
bee
bee terminal
bee codex
```

Run from the desired project directory. The native program must be installed on
PATH. Existing runtime registry state may retain an earlier selected deployment;
`bee --base` selects the embedded base while preserving application databases.
See `README.md` and `DEVELOPMENT.md` for the distribution/development distinction.
There is no stable published release implied by these instructions.

## Still required for the requested Hive direction

The local foundation does not complete the broader requested headless/Hive work.
The next implementation must separate the stable workspace host from the physical
terminal client, keeping broker and database ownership together. The broker
currently monitors its owner and stops when that owner exits; simply renaming the
current presenter or adding a headless flag does not establish that boundary.

Implement client admission and detach separately from app close and host shutdown;
retain pending questions without treating disconnection as consent. Then prove
two independent client layouts, qualified tabs from two workspaces, and an actual
remote Bee Terminal through destination admission. Native cross-host TTY tests do
not substitute for those gates. Only then expose the headless profile, workspace
switcher and Hive Manager. Fresh local launches must remain local-only.

Application drivers and installation/self-edit subsystems are subsequent work,
not extra responsibilities to put into the desktop loop.
