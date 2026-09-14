# Shell refinement

Four focused passes prepare the desktop for the next foundation phase.

1. **Window controls.** Minimize is the primary hide action, available from the
   title bar, Start and Alt+F9. Muted tabs identify minimized windows; clicking a
   tab or Alt+Tab restores them, including when every window is minimized.
   Maximize and close have separate visible controls. Collapsed windows remain
   available as a secondary option, with a complete flat bar that can be dragged
   without losing its expanded dimensions.
2. **Input ownership.** Focus and minimize predict input ownership while drawing
   remains committed session state. Correlated acknowledgements settle even
   no-op commands. Clicking the desktop clears focus. Escape cancels a drag;
   resize and application closure release capture safely. Regression scenarios
   send shortcuts and text in the same terminal read.
3. **Appearance and small windows.** Settings remains an independent process.
   Its 16 themes and 11 backgrounds have clickable previews using the same
   wallpaper renderer as the desktop. Wheel and Page Up/Down browse without
   changing preferences. Short windows use compact selection controls. Frame
   and body backgrounds agree across light and dark themes.
4. **Lifecycle and verification.** Protocol tests validate acknowledgement data
   and copied scene ownership. Source and packed acceptance exercises repeated
   presenter replacement, crash recovery, retry exhaustion, independent app
   state, window geometry, input isolation and prompt shutdown. Registry audits
   exclude legacy code, fixtures and test entries from the production package.

New floating windows fill each available cascade position before a position is
reused. Process Manager disambiguates equal process names with a short process
identity and calls its destructive action Stop consistently. The F9 connection
card names controller state directly and uses explicit close wording.

Live presenter replacement preserves application producers, window state and
appearance. Local SQLite migrations and opt-in application checkpoint/restore
now preserve workspace state across full restarts, as described
in [WORKSPACE_STATE.md](WORKSPACE_STATE.md). General installation, MCP and agent
drivers remain separate from the desktop.

After this update, exit with Ctrl+Q and run `bee` again: changes include the
stable workspace and session processes, which F12 does not replace.

## Second refinement round

1. Reduced Start to a hierarchical launcher (Tools and Exit), moved window
   actions to title/tab context menus, and added hover selection. Nested levels
   support click/Right to enter and Left/back to return. No instruction legend
   or duplicate menu heading consumes rows.
2. Added the on-demand Process Manager with measured heap, scheduler and queue
   histories, pause, stable row identity, sorting and broker-scoped app closure.
3. Fixed the drag-drop handoff: retain the preview until committed geometry
   arrives. Acceptance checks every synchronized frame during the handoff.
   Contextual restore also restores input ownership.
4. Separated core, shared UI and default apps; added supervisor inspection,
   counter-reset/gap handling, small-window checks and source/pack lifecycle
   coverage. Documented independent package and future self-edit boundaries.

The panel-colored Settings frame is retained: the frame and body share one
surface color, with contrast against the desktop. This avoids mismatched border
bands across light and dark themes.

Compact Settings now retains an error row and truncates long selection labels
with an ellipsis. Wallpaper previews use the desktop background token, including
Windows Classic. A failed final drag-placement send releases capture and reports
the error instead of waiting indefinitely for an acknowledgement that cannot
arrive. The successful drag handoff still retains its preview until committed.

Native Terminal now launches Bash for interactive editing; `/bin/sh` can resolve
to Dash, which echoes arrow escape sequences at its prompt. Runtime #653 also
preserves legacy navigation modifiers, Shift+Tab and application-mode Home/End.
`tests/navigation.py` verifies 161 actual PTY deliveries through the desktop and
viewport; `tests/console.py` verifies Readline editing and history navigation.
Runtime proxy tests additionally cover function keys, release suppression and
Kitty keyboard modes. Reserved shell shortcuts remain desktop operations.


## Remaining UI requests and current boundary

The maintained shell includes standalone Settings, themes/background previews,
nested Start navigation with hover, title/tab context menus, four-corner resizing,
minimize/maximize/restore, and a process/service monitor. Source/pack acceptance
covers these interactions and the drag handoff. DOS Blue and Windows Classic add
retro palettes; selection text has its own semantic color so navy selections
remain readable on a teal desktop. Background choice remains independent; Solid
is the closest match to the classic desktops.

The reported Claude resize/repeated-text artifact remains unconfirmed, not fixed.
The supplied screenshot was inspected: `Testing` appears to the right of the
input cursor, but the image does not establish the source of that text. Native
Terminal acceptance now types a wrapped line, resizes from all four corners,
erases it and verifies that no stale input cells remain in source and pack.
The boot and empty-desktop mark now use a compact cell-native bee with a lowercase
wordmark, a plain small-terminal fallback and no timed splash delay. Settings →
Tabs selects Labels or Icons. Admitted app icons travel
with window state; icon tabs retain focus, minimize and overflow behavior, with
a short title fallback for apps without icons. The preference survives cold
restart and F12. Old preferences default to Labels. The legacy demo Studio/chat/training apps are not restored into the
new core. Agent-driven layout/settings operations are not yet published through
MCP. These requests must not disappear behind the subsystem roadmap.

## Instance titles and accents

User labels and accents are implemented. Right-click a title or tab and choose
Rename or Accent. Rename supports selection, cursor movement, grapheme deletion,
bounded paste, Enter/Save and Escape/Cancel. An empty label restores the app title.
The dialog consumes input; it does not type into the underlying terminal.

The session owns `user_title` and `accent` independently of the application title.
Labels are limited to 80 bytes with no control characters. Accents are named
Amber, Cyan, Green, Rose or Violet, with a theme-default reset and contrasting
light/dark palette variants. They color chrome only. Identity, permissions and
application content colors do not change. Values survive F12 and supported cold
application recovery; labels do not resurrect dead native PTYs.

Source/pack acceptance covers two separately named terminals, modal input
isolation, cancel/clear, accents, minimized restore and Settings cold recovery.
A fixture also verifies that an app cannot submit a private personalization
command directly to the workspace. Application title announcements are implemented
through `bee.application:client.title`; native OSC forwarding remains future work.
An application announces recorded events through its title (the Timeline
names its thread and state as the owner reports them); announcements describe
recorded events, not proof of current liveness.

Multiple terminals need distinguishable names. Keep the definition's launcher
title, the application's announced instance title, and the user's title override
separate. Display the user override first, then the announced title, then the
definition title. Clearing the override returns to the latest announced title.
Renaming never changes definition, instance, view or workspace identity.

An app may announce only its own title through an authenticated broker operation;
the broker checks actual sender PID, instance/view IDs and launch token. Bound
titles, reject terminal controls, coalesce repeated announcements and commit
changes through the session. A user override must survive further announcements
and presenter replacement. Save overrides with supported application restoration;
do not imply that saving a Terminal label resurrects its dead native process.

Expose Rename and an optional accent selector in the title/tab context menu.
Accents distinguish instances in tabs and frame details, remain readable in every
theme and do not override application content backgrounds or workspace labels.
The future client-layout owner owns user labels and accents; the application owns
its announced title.

Native programs commonly announce titles using OSC 0/2. The current Bee Terminal
attachment exposes no title event in the inspected TTY/proxy boundary. Verify and,
if needed, add a bounded native title notification there, then let the Terminal
app forward it through the same title operation. Do not parse or duplicate the
PTY output stream in Lua. Programs that do not announce a title can still be
renamed manually.

Acceptance must cover two independently named terminals, unauthorized cross-app
rename, control/oversize rejection, repeated announcements while an override is
active, clearing the override, minimized/overflow tabs, presenter rejoin and
supported cold restore. Native OSC reporting needs a real PTY test, including
split escape sequences; an API-only test does not prove that path.

## Window-local text selection (candidate)

The candidate presenter offers **Select text** in a window's title/tab context
menu. It freezes that window's visible rows; left-drag selects only its body,
Ctrl+C requests a copy, and Escape cancels. Hovering after release does not move
the range. Application input resumes after successful submission. Resize,
attachment replacement and presenter retirement cancel selection. A request
has an 8 KiB text limit and a ten-second feedback deadline.

Local physical clients use the runtime surface's explicit clipboard method,
serialized with frame writes. This requires runtime PR #722, together with
PR #720 for native plain-text extraction. Success means an OSC52 request was
submitted; the user's terminal may ignore it. Neither clipboard text nor the
selection enters retained frames, checkpoints or databases.

`make terminal-selection-check` passes source and pack on the candidate: two
actual overlapping Terminals, exact foreground clipboard text decoded from
physical output, hover stability, resumed keyboard input and no replay after
cancellation/rejoin. Model/render tests cover Unicode and ANSI extraction,
geometry bounds and highlighting. The global Bee now includes this tested
candidate; installed-executable acceptance also passes physical selection/copy.
Use `bee --base` to select its embedded baseline. The release runtime pin still
awaits upstream cutover.

Compiled remote physical-client copy routing remains unimplemented. Its native
actor inbox can carry a recipient-specific operation, but virtual surfaces
currently return unsupported instead of broadcasting a clipboard effect.

## Terminal scrolling candidate acceptance

`make terminal-scroll-check` exercises physical SGR input through the real Bee
presenter and native Terminal, from source and pack. It covers a wheel notch,
trackpad-style repeated events, downward scrolling and subsequent keyboard input.
The baseline fails on the first notch because native proxy history retains
only one line. Runtime PR #719 supplies bounded history; PR #705 also fixes Unix
input framing so a burst crossing a read boundary cannot become shell text.
The combined candidate passes this regression from source and pack, all 161
navigation cases, and the existing Terminal source/pack acceptance.

History retains at most 256 lines with a cell budget and conservative resize
limits. Once retained history is full, new output can move a scrolled viewport;
the emulator does not expose stable history-line identities. Windows keeps its
existing console reader. These changes are not in Bee's release pin or global
binary. Device-specific trackpad behavior and a real Codex conversation still
require acceptance; synthetic wheel events are not hardware verification.

Installed executable acceptance now also runs the same wheel-notch, 12-event up
burst, 40-event down burst and resumed-keyboard checks against global `bee`. It
targets the visible Terminal body while Settings remains behind it. Evidence:
`/tmp/bee-global-scroll-check-2.log`. These are terminal protocol events; actual
hardware trackpad behavior and a live Codex conversation still need observation.

## Final terminal UX audit

The 2026-09-14 production audit covered all 416 Lua source files with separate
Promptmap passes for consistency, layout and input, visual language, repetitive
implementation patterns, and accessibility. Verified fixes keep unavailable
Timeline rows from offering stale actions, add keyboard guidance to Timeline and
Approvals, preserve Process Manager mode and health at narrow widths, bound its
native sampler text, and make profile action styling match the accepted action.
Window cascades now fill each grid slot once, compact recovery plans cannot be
accepted before they can be reviewed, and Hive, connection, picker and process
copy use the same direct platform language. The review introduced no new UI
framework or presentation vocabulary.
