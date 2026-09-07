# Local desktop implementation boundary

Decision: build a maintained desktop with a native Terminal as its first useful
application. Workspace bindings and admission precede Terminal. This document
narrows the larger foundation roadmap; the sections below describe the target,
not features already implemented. See FOUNDATION_STATUS.md for shipped behavior.

## One local workspace first

A workspace has a stable ID, a project directory binding, a private state
directory, and a reviewed application composition. The initial implementation
has one workspace per runtime. Multiple attachments, remote filesystems and
shared catalogs must not be prerequisites for opening a local shell.

Keep three locations distinct:

- Core source or embedded pack: application code and protected boot declarations.
- Project root: the folder selected by the user, exposed through a named runtime
  filesystem resource. It is not implicitly the Bee installation directory.
- Workspace state: identity, committed desktop preferences and reopen records.
  Registry history has its own store; it is not the layout database.

The launcher must resolve the requested project before changing directories to
load the core. Persist its identity rather than using a display path as identity.
Moving a workspace changes its binding; copying it requires an explicit identity
decision. Initial storage can be local SQLite with one workspace owner. No global
database or cross-machine synchronization is required.

Boot configuration binds existing Wippy resource kinds such as `fs.directory`.
Do not create a filesystem server or put individual files in the registry.
Resource references use a binding ID plus a path within that binding; native
absolute paths are resolved only by an admitted native execution adapter.
Filesystem operations must use the runtime provider's containment checks, not
string-prefix authorization implemented in Lua.

An `exec.native` shell runs with its OS user's privileges. A working directory
and an `fs.directory` resource do not sandbox that child. Admission must make
native execution a separate capability; a container executor can be another
binding later. Do not label a local native terminal as project-confined.

## Registration uses the runtime registry

An application definition remains a `process.lua` entry with versioned
`bee.application` metadata. Its registry ID identifies executable code; its
instance ID identifies one launch; its view ID identifies a presentation.

The application authority validates admitted definitions and projects a small
catalog for the desktop. A definition declaring itself an application does not
grant itself discovery, launch or filesystem access. Protected admission and
resource bindings determine those rights. The desktop never reads raw registry
records or constructs child security policies.

There are three distinct operations, not one universal registrar:

| Operation | Owner | Effect |
|---|---|---|
| Install or update a definition | Installation/publication authority | Validated registry change |
| Open an admitted application | Application authority | Instance creation and scoped view attachment |
| Open a resource | Resolver using admitted handler metadata | No match, one handler, or chooser |

Start with exact application IDs and one Terminal definition. Add handler
metadata when a second application needs resource opening. Future handlers
declare actions and content types in registry metadata; selection is followed
by fresh admission. A chooser never supplies authority. A registry change
invalidates discovery but does not automatically restart running processes.

Saved experiments and Hub installs can feed this same catalog later. They do
not need separate desktop launch paths. Core release updates and user-owned
overlays remain separate publication lanes.

## Shell structure

| Layer | Responsibility |
|---|---|
| Workspace owner | Bindings, authenticated attachment, state store and lifetime |
| Application authority | Admission, instances, producer-owned viewports and mounts |
| Desktop session | Committed window state, focus, preferences and stable tab order |
| Layout library | Pure rectangles for workspace, chrome, windows and popups |
| Theme library | Validated semantic colors and deterministic background settings |
| Renderer | Draw a scene using those rectangles and theme values |
| Input controller | Hit tests against the same rectangles; transient captures |
| Physical terminal adapter | TTY lease, event pump and final presentation |

Do not grow the current terminal main loop into a second POC manager. Split
layout, drawing and input at these boundaries before adding settings and menus.
Only the adapter handles terminal events; only the session commits desktop state.

Appearance is an independent app, installed but closed in a standard desktop
composition. Bare core remains a valid composition. Appearance sends validated
preference requests through the desktop authority; it does not write session
tables, registry policies or viewport grants directly.

Preferences are versioned data: theme ID, background kind and parameters, bar
placement and motion preference. Resolve one theme snapshot per revision, with
semantic colors for ground, surface, text, muted text, border, accent and status.
Backgrounds fill every desktop cell. Application default colors come from the
runtime viewport page; explicit application colors remain explicit.

Compute reserved chrome and usable workspace once. Rendering and hit testing
share the result, including top/bottom bar placement and tiny terminals. Clip
text by terminal cell width, not byte count. Frames and popup borders count
toward their bounds. Pointer capture uses committed bounds plus a local preview;
resize the application viewport only after commit. Menu input captures key,
paste and pointer consistently. Scrolling belongs to explicit bounded regions.

## Replacement and restoration

The workspace now owns broker and session lifetimes independently of the
presenter. Live presenter retirement/rejoin and unexpected-exit recovery are
covered by source and packed PTY tests. Workspace persistence has since shipped;
see [workspace state](WORKSPACE_STATE.md) for its exact boundary.

The application authority owns producer viewports; a replacement presenter
receives fresh recipient-bound mounts. Application processes remain running;
native PTYs will need equivalent acceptance when Terminal is added. Acknowledged
retirement, runtime EXIT and mount revocation fence the replacement. The physical
TTY lease stays with the workspace adapter throughout, so no physical lease
handoff is needed. A native release update still needs its own install protocol.

Runtime source review (`system/scheduler/actor/worker.go`, `StepUpgrade`) shows
that `process.upgrade` preserves the PID and scheduler queue generation, but
closes the old Lua process before initializing its replacement. Creation or
initialization failure completes the process with an error. It is therefore
not a ready-before-swap transaction with an automatic fallback to old code.
Successful PID preservation alone does not establish physical surface or Lua
handle continuity. Prefer a separately owned presenter replacement protocol
for recoverable desktop updates; test native resource ownership explicitly.

Persist committed preferences, window geometry, mode, stable ordering, focus
and logical reopen descriptors. Never persist PID, mount token, userdata or
input capture. Coalesce writes after commits; pointer motion and frame painting
do not write the database. A live rejoin requests an authoritative scene and
fresh mounts. A cold restart resolves reopen descriptors under current policy.

Cold restoration does not rerun arbitrary commands. A missing application or
lost terminal job gets a recoverable placeholder. Restoring a terminal window
and recreating a terminated shell are different user-visible operations.
Application-owned state remains in the application; desktop layout persistence
does not pretend to checkpoint Python, shell jobs or conversations.

## First useful application: Terminal

Terminal is a standalone process using the admitted executor, resolved working
directory and its assigned producer terminal. Use runtime `attach_terminal()`
for PTY bridging, input, resize and terminal protocol handling. Do not implement
ANSI emulation or per-character forwarding in Bee Lua.

Launch the configured shell without interpolating resource paths into command
text. Pass the directory as execution options. Define the child's environment
explicitly; runtime service credentials must not become ambient shell state.
Each launch creates an independent instance. Focus, minimize and presenter
replacement do not restart it. Closing a view follows its declared lifetime;
stopping a shell is an explicit lifecycle decision, never an accidental effect
of a UI redraw or settings update.

## Implementation order and release evidence

1. Resolve workspace identity, project/state bindings and the authenticated
   boot owner. Test launching from outside the installation and packed loading.
2. Move broker/session lifetime under that owner. Test presenter loss, stale
   attachment rejection and fresh mount rejoin while a producer keeps counting.
3. Split shell layout, theme, rendering and input; persist committed scene and
   preferences. Test every edge/corner, bar placement, tiny screens, Unicode,
   popup capture and resize/focus sequences.
4. Admit Terminal with a dedicated execution policy and explicit environment.
   Test two independent shells, full-page default colors, explicit colors,
   resize, process completion, close and prompt runtime exit.
5. Add Appearance and native release refresh only after rejoin and failure
   recovery pass. Keep bare-core and standard-desktop packaging checks separate.

No AI, MCP, shared catalog, remote mount browser or generalized plugin installer
is required to pass these gates. Their future extension points are admitted
definitions, resource bindings and logical view contracts.

## Desktop operations for agents

The desktop is also a controllable workspace, not only a renderer. Its public
operation boundary will serve local applications and authorized external agents
through the same typed requests. MCP is a separate adapter application; it must
not own layout state, terminal producer grants, or a second application catalog.
This is the next integration contract, not an MCP server already included in Bee.

| Operation | Result and authority |
|---|---|
| Inspect desktop | Value snapshot of windows, focus, modes, geometry and appearance; requires observation authority |
| Set appearance | Validated theme/background preferences through the workspace owner |
| Arrange windows | Focus, place, snap, minimize, collapse, restore and fullscreen through the session model |
| Open application | Resolve an admitted registry definition and ask the broker to create an instance |
| Close application | Close a view-owned instance within the caller's permitted workspace |
| Subscribe to changes | Revisioned value updates; no raw viewport grants in external responses |

Registry trait metadata advertises these operations for discovery. It does not
confer permission. The workspace must authenticate the adapter's actual process
identity and separately authorize the connected agent session. Observation,
appearance changes, layout changes and application launch are distinct rights.
Installing code, changing protected registry entries and self-modification remain
separate capabilities, never implicit consequences of desktop control.

Each request carries a correlation ID and targets a workspace and, where needed,
a stable application instance ID. Mutations return the committed revision or a
typed rejection. Layout edits should accept an expected revision so an agent can
avoid overwriting a concurrent user's drag. External tool results contain domain
values, not internal PIDs or delegated terminal capabilities. An MCP adapter can
therefore inspect, change a theme, arrange windows or launch an admitted app using
the same owner/session/broker path as the UI, without synthesizing keystrokes.

The current shell already routes window operations to the session and application
lifecycle to the broker. Settings runs independently and requests validated
appearance updates. General caller admission, correlated public operation
results, expected-revision writes and MCP transport are still to be implemented.
