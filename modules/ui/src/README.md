# bee.ui

Shared presentation helpers for applications and the desktop. `bee/ui` has no
application SDK, Harness or Threads dependency. Import these entries directly;
they grant no application, workspace or thread authority.

| Entry | Responsibility |
|---|---|
| `appearance` | Semantic themes, preference validation, styles and the host's nonsecret `NO_COLOR` selection |
| `text` | Bounded external text with control replacement and truncation on a UTF-8 character boundary |
| `frame` | The application frame every Bee application draws with: size classes and layout, header, tabs, action bar, bounded status and reserved key-hint footer, declared-action Help and overflow More menu, list window, table, tree view, key-value inspector and log viewer (full width, or confined to a pane's `area`), panels, form fields, wizard steps, empty state, virtualized log viewer with search highlight, status badge, toast, modal and command palette (`fuzzy` filter) |
| `bee.ui.viz:viz` | The visualization kit on the frame: sparklines, line and area charts, bars, columns, stacked bars, histograms, heatmaps, status grids, gauges, progress, stat tiles, inline table bars, timelines, small graphs, scatter plots, candlestick and range charts, a braille radial gauge, a spinner, 100% stacked bars, progress with ETA and bounded live series with a redraw cadence |
| `bee.ui.forms:forms` | The input kit on the frame: a text field (cursor, word and line motions, select-all, paste, placeholder, `max_length`, masked mode), a bounded number field, a scrolling multi-line text area, a select/dropdown, a checkbox, a radio group and a toggle, plus a form container that owns focus order (Tab/Shift-Tab/click), per-field validation, dirty tracking and a disabled state |
| `bee.ui.diagram:diagram` | Layout diagrams on the frame: `mesh` (nodes at chosen or ringed positions, braille-routed edges, node hits), `treemap` (squarified tiles of sized items) and `flame` (icicle chart of a value tree); pure painters with hit targets, in the same node and bar vocabulary as `viz` |
| `bee.ui.picker:folder` | A folder picker over the roots the host admits through the workspace catalog's `roots` and `folders` operations: the pure paging and navigation model and its table on the frame |

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
`text: bee.ui:text`. Import the kits as `forms: bee.ui.forms:forms`,
`viz: bee.ui.viz:viz`, `diagram: bee.ui.diagram:diagram` and
`folder_picker: bee.ui.picker:folder`. The picker accepts the shared
`bee.values:reply` envelope and returns workspace catalog call intents; the
application dispatches them through its authorized owner client.
