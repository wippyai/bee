# bee.ui

Shared presentation helpers for applications and the desktop. `bee/ui` has no
application SDK, Harness or Threads dependency. Import these entries directly;
they grant no application, workspace or thread authority.

| Entry | Responsibility |
|---|---|
| `appearance` | Semantic themes, preference validation, styles and the host's nonsecret `NO_COLOR` selection |
| `text` | Bounded external text with control replacement and truncation on a UTF-8 character boundary |
| `frame` | The application frame every Bee application draws with: size classes and layout, header, tabs, action bar, bounded status and reserved key-hint footer, declared-action Help and overflow More menu, list window, table, tree view, key-value inspector and log viewer (full width, or confined to a pane's `area`), panels, form fields, wizard steps, empty state, virtualized log viewer with search highlight, status badge, toast, modal and command palette (`fuzzy` filter) |

Shared frame controls are application-owned values. Views return
`controls = frame.controls(painter)` with their rows and hits. The actor owns
a `frame.menu()` record, calls `frame.render(drawn, menu, preferences)` before
presenting, and routes terminal events through `frame.route(menu, event, text_entry)`
before its normal handlers. Nil means consumed; the second return value requests
a redraw. More dispatches an enabled choice through the actor's existing mouse
handler. Help lists declared buttons, tabs and hints, including unavailable
actions. `Button.key` names the shortcut; `primary` reserves room when buttons
overflow. Text entry preserves case and literal `?`; the Help footer stays
clickable. Neither overlay grants permissions or bypasses app confirmations.

Appearance reads only the existing `bee.env:no_color` flag under the caller's
host-selected permissions. The presenter strips color from incoming rows when
the flag is set; selection also uses glyphs and reverse video.

Apps import `frame: bee.ui:frame`, `appearance: bee.ui:appearance` and
`text: bee.ui:text`. Visualization, forms, diagram and folder-picker helpers
remain in `bee.app` and use this package's frame and appearance.
