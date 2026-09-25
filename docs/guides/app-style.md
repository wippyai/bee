# Application visual style

Read this page before drawing any Bee application. It states the rules every
terminal application follows, and each rule names the
`bee.application:frame` function that implements it. The
[brand book](ui.md) explains the intent behind the rules; this page is the
contract. When a rule and a wish conflict, follow the rule.

## 1. Grid

- The unit is one terminal cell. Coordinates are one-based: column 1 is the
  left edge, row 1 the top.
- Column 1 and the last column stay blank except for the selection marker
  `›` in column 1. Content starts at column 2 and ends one column before the
  right edge (`frame.line`, `frame.layout(...).work`).
- Gaps are 1, 2, 4 or 6 cells. Two cells separate side-by-side regions and
  table columns; one row separates stacked regions (`frame.split`,
  `frame.stack`, `frame.grid`).
- No borders around regions. A region is named by a muted uppercase title on
  its first row (`frame.panel`). A full-width `border` rule (`frame.rule`) may
  separate the navigation from the work once per screen.

## 2. Anatomy

`frame.layout(painter, tabs, actions)` returns the rows below; draw into them
and nowhere else.

| Row | Region | Function |
|---|---|---|
| 1 | Header: uppercase identity left, muted live summary right | `frame.header` |
| 2 | Tabs, when the application has sections | `frame.tabs` |
| 3 | Blank | — |
| 4 … H−2 | Work area, columns 2 … W−1 (from row 3 without tabs) | `layout.work` |
| H−1 | Action bar | `frame.actions` |
| H | Footer: status left, key hints right | `frame.footer`, `frame.hints` |

Below 6 rows the tabs and the action bar are omitted and the work area runs
from row 2 to H−1; below 2 rows only the header remains. The key hints always
name every action the omitted bar offered.

## 3. Size classes

Layouts change only at these breakpoints (`frame.size(width, height)`). Both
dimensions must reach a class.

| Class | From | Work area | Dashboard grid | List + detail |
|---|---|---|---|---|
| `narrow` | below 80x24 | identity, selection, one value | 1 column, first panel only | list only, Enter opens detail |
| `compact` | 80x24 | 78x19 | 2 columns x 2 rows | list only, Enter opens detail |
| `standard` | 120x36 | 118x31 | 3 columns x 2 rows | list 40 cells, detail rest |
| `wide` | 160x48 | 158x43 | 4 columns x 2 rows | list 48 cells, detail rest |

A narrow canvas keeps the identity, the current state and one route forward.
A wider class may add panels, metadata and a detail pane; it never removes
what the smaller class shows. Never scroll a primary workflow horizontally.

## 4. Actions

- The action bar is the penultimate row, starting at column 2
  (`frame.actions`). Order: the primary action first, then secondary actions,
  then toggles, then destructive actions last.
- Exactly one enabled button per screen is `primary`: the action Enter
  performs. It is filled: `selection_text` on `accent`. Secondary buttons are
  `accent` text on `surface`. A selected toggle is `active` and filled like the
  primary.
- A button with a key shows it first: `" R Refresh "` (`Button.key`). The key
  and the verb match the footer hint.
- Disabled buttons stay visible in `muted` and record no hit target.
- Destructive work asks first: the footer becomes
  `Stop selected app? Enter confirms · Esc cancels` and the destructive button
  becomes the primary until the choice is made.

## 5. Status and key hints

- The footer is the final row (`frame.footer`). The status at the left is a
  sentence naming the latest effect or the current state: `Saved count 2`,
  `Waiting for approval`, `Paused`. The key hints at the right use
  `frame.hints`: key, space, lowercase verb, joined with ` · `.
- When both do not fit the status wins and the hints are dropped. With no
  status the hints stand alone at the left.
- The header summary (`frame.header`) is the live one-line state of the whole
  screen: `Live · 1s · 42 processes`. It is muted and truncated before the
  title.

## 6. Color roles

Use `bee.application:appearance` roles; never write a hex value in an
application. `appearance.role(theme, name)` resolves a role by name.

| Role | Allowed on |
|---|---|
| `text` | Primary content and values |
| `muted` | Labels, panel titles, axes, units, metadata, key hints, disabled controls, the empty part of a meter |
| `border` | The one navigation rule and graph edges |
| `accent` | Focus, the selected row or tab, the primary action, and the primary data series of a chart |
| `selection_text` | Text drawn on `accent` only |
| `ok` | A state word that reports success (`Ready`, `Passed`), and data marks inside a declared healthy range |
| `warn` | A state word that asks for attention (`Degraded`, `Waiting`), and data marks past a declared warning threshold |
| `error` | A state word that reports failure (`Failed`), an inline field error, and data marks past a declared failure threshold |

Rules:

- A status color never appears without the words or numbers that carry the
  same meaning in the same row. `ok`, `warn` and `error` never color a
  whole row, a background, a border or a title.
- `accent` means focus. One screen has one accent selection, one primary
  action and at most one accent data series.
- Charts distinguish series by glyph first and by role second, so the chart
  reads in the `Mono` theme.

## 7. Selection and focus

- A selected row keeps its text, takes `selection_text` on `accent`, and
  carries `›` in column 1 (`frame.row`, `frame.table`). Focus is visible
  without color.
- When another pane owns focus the selection keeps `›` and `accent` text on
  `surface` (`focused = false`).
- The whole row is the mouse target. A selected tab is `selection_text` on
  `accent`; inactive tabs are `muted`.
- Keep a stable key per row (`Table.keys`) so a refresh keeps the selection
  on the same item, and keep the selection visible with `frame.window`.

## 8. Truncation

- Every text run is truncated by display width with `…` (`frame.put`,
  `frame.fit`). Decoration (bars, rules, patterns) is clipped without an
  ellipsis (`frame.clip`).
- Truncate in this order: the header summary, then metadata columns, then the
  flexible column. A table too narrow for its flexible column folds each row
  into `first cell · other cells` (`frame.table`).
- External text passes through `bee.application:text.bound` with a byte
  ceiling before it reaches the frame.
- Numbers are right-aligned (`Column.align = "right"`) and never truncated;
  shorten their unit instead (`12.4 MiB`, `1.2k`).

## 9. Empty, loading and error states

All three use `frame.empty(painter, y, title, action)` at the top of the
work area: what is absent or wrong on the first row, the next useful action on
the row below it.

| State | First row | Second row |
|---|---|---|
| Loading | `Loading processes from this workspace` | `Esc close` |
| Empty | `No runs yet` | `R start a run` |
| Error | `Could not read memory statistics` | `R retry · the rest of the screen stays live` |
| Unavailable | `Node disconnected` | `Retrying every 5s · Esc close` |

A panel that fails keeps its title and shows its own
`frame.empty(painter, y, title, action, area)` bounded to its rectangle; the
other panels stay live. A missing sample in a chart is a gap,
never a zero.

## 10. Mouse targets

- Every target is recorded while drawing (`frame.add_hit`, or implicitly by
  `frame.row`, `frame.table`, `frame.tabs`, `frame.button`, `frame.field`) and
  resolved with `frame.hit(hits, x, y)`.
- Rows span the full width. Buttons and tabs span their padded label. A
  target is at least one row high and three cells wide.
- Every mouse action has a keyboard route with the same verb, and every
  button's key is listed in the footer hints.

## 11. Archetypes

Pick the archetype that matches the request, then fill it. Coordinates below
are the `compact` class (80x24) unless marked.

### List and detail

A collection of items with properties. `frame.table` for the list; on
`standard` and `wide` a detail pane beside it through
`frame.split(work, {40, 0})` with `frame.panel` and label/value lines.

```
 PROCESSES                                          Live · 1s · 42 processes
  Processes   Services

 NAME                                   STATE      STEPS   DETAIL
› bee.host:main                          running       96   PID    0x0017
  bee.session:main                       idle          16   Host   workers
  bee.apps:broker                running       70   Steps  96
 ...
  Pause    Sort: name    Stop app
 3 selected                          ↑↓ select · Tab switch · Esc close
```

The `DETAIL` pane appears only from `standard`; on `compact` Enter opens the
detail as a second page and Esc returns.

### Dashboard grid

Several independent measurements. `frame.grid(work, columns, rows)` with the
column and row counts from section 3; each cell is a `frame.panel` holding one
visualization. The most important panel is first in reading order. Stat tiles
(`viz.tiles`) take the first three work rows above the grid. The toolkit
document in the agent corpus shows tested visualization calls and compact
examples for composing them into a screen.

```
 SYSTEM                                             Live · 1s · 3 alerts

 HEAP                    12.4 MiB    SCHEDULER            840/s
 ▁▂▂▃▄▅▅▆▆▇█▇▆▅▅▄▃▃▂▂▃▄▅▆▇█▇▆▅▄    ▃▃▄▄▅▅▆▆▅▅▄▄▃▃▄▅▆▇▇▆▅▄▃▃▂▃▄

 PROCESSES BY STATE                  QUEUE
 running  ██████████████▌  31        ▏0     ▁ ▁ ▂ ▃ ▂ ▁
 idle     █████▎           11
  Pause    Refresh
 Sampled 1s ago                       P pause · R refresh · Esc close
```

### Form

Values the user edits. One `frame.field` per row, labels padded to the
longest label, the selected field is the edited one, errors inline after
` · ` in the `error` role, the primary action is `Save`.

```
 NEW SERVICE

 Name      billing
›Port      99999 · must be below 65536
 Restart   automatic

  Save    Cancel
 Port is invalid                        ↑↓ field · Enter edit · Esc cancel
```

### Wizard

A task in ordered steps. `frame.steps` on row 3 (under the header, or under
the tabs row when present) shows progress; the work area holds the current
step's form or review; the primary action is `Next`, `Back` is secondary, and
the last step's primary names the effect (`Deliver`).

```
 DELIVER APPLICATION
  ✓ Source  ›  2 Review  ›  3 Deliver

 Review
 Entries   3 process.lua · 1 library.lua
 Verdict   ready

  Next    Back    Cancel
 Step 2 of 3                              Enter next · Esc cancel
```

On a narrow canvas the strip folds to ` Step 2/3 Review `.

### Log and stream

An append-only sequence. `frame.row` per line in a `frame.window` pinned to
the newest line; the header summary says whether the view follows; a selected
line stops following. Keep at most the lines the window can show plus a
bounded history (`viz.series` for numbers, a fixed-size list for lines);
never grow without bound.

```
 BUILD LOG                                         Following · 1,204 lines

 18:02:11  compile  bee.application:frame
 18:02:12  lint     507 entries, 0 errors
›18:02:14  test     frame_test 11 passed
  Follow    Clear
 Paused at line 1,203                      ↑↓ scroll · F follow · Esc close
```

### Monitor with live charts

A measurement over time. A top row of stat tiles, then one large chart, then
a table of the items behind it. The redraw cadence is fixed (1 s by default)
and stated in the header summary; data arriving faster is buffered, not
drawn. Draw it with `viz.tiles`, `viz.line` and `frame.table` (section 12).

```
 MONITOR                                                          Live · 1s

 HEAP                GOROUTINES          GC                  QUEUE
 12.4 MiB ▲0.8       214                 38                  0
 ▂▃▄▅▆▇█▇▆▅▄▃▂▂▃▄▅▆  ▅▅▅▅▆▆▆▆▅▅▅▅▆▆▆▆▆▆  ▁▁▂▂▃▃▄▄▅▅▆▆▇▇██▇▇  ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁

 HEAP                                                              12.4 MiB
 16 MiB ┤  ⢀⡴⠚⠉⠙⠲⣄            ⢀⡴⠚⠉⠙⢦⡀
        │ ⣠⠏     ⠘⢦⡀         ⣰⠋     ⠙⢦
  0 MiB ┤          ⠳⣄      ⢀⡞⠁       ⠈⠳⡄
        └──────────────────────────────────
         -60s                           now

 PROCESS                                    STATE          STEPS
› bee.host:main                              running           96
  Enter Refresh   P Pause
 Sampled 1s ago                          Enter refresh · P pause · Esc close
```

## 12. Visualizations

The visualization kit is `bee.application:viz`. Choose by the question:

| Question | Function |
|---|---|
| How is one value moving? | `viz.sparkline` |
| How did values change over a window? | `viz.line` (area with `area = true`) |
| How do categories compare? | `viz.bars` (horizontal), `viz.columns` (vertical) |
| What is each category made of? | `viz.stacked` |
| How are values distributed? | `viz.histogram` |
| Where is activity concentrated in two dimensions? | `viz.heatmap` |
| Which of many items pass or fail? | `viz.waffle` beside the counts in words |
| How full is one capacity or how far is one task? | `viz.gauge`, `viz.progress` |
| What are the headline numbers? | `viz.tiles` |
| How do rows compare inside a table? | `viz.bar_cell` in a `frame.table` column |
| What ran when? | `viz.timeline` |
| How are nodes connected? | `viz.graph` |
| How do I keep a live series bounded? | `viz.series`, `viz.push`, `viz.values`, `viz.cadence`, `viz.due` |

Chart rules:

- Every chart has a `frame.panel` title naming the measure (`HEAP`), the
  latest value in the panel summary, axis labels at the minimum and maximum
  with units, and the time window on the axis (`-60s … now`).
- The primary series is `accent` and solid; the second and third series use
  `text` and `muted` and are dotted. At most three series share one chart;
  stacked segments use the shades `█ ▓ ▒ ░` with a legend row.
- A missing sample is `viz.GAP` and draws as a gap (`·` in a sparkline).
- Thresholds are declared values (`warn`, `error` on `viz.Scale` and
  `viz.Meter`); marks past them take the status role and the numeric value
  stays printed.
- Heatmap intensity uses the shades `░ ▒ ▓ █` of one role, zero is a muted
  `·`. A status grid (`viz.waffle`) packs two items per cell and is always
  accompanied by the counts in words (`500 tests · 463 passed · 37 failed`).
- Graphs are small topologies (up to `viz.GRAPH_NODES` nodes) laid out left
  to right by dependency; edges are `border` lines ending in `▸`, a node's dot
  carries its status role and its label and note carry the words.
- Charts draw inside the rectangle they are given and never outside it; they
  hold no state between frames. Live state lives in a `viz.series` owned by
  the process, pushed on each sample and read in the pure view; a
  `viz.cadence` decides when the process repaints.

## 13. Acceptance

Test every view at the three breakpoints plus one narrow size: exact row
count, exact display width for every row, every hit inside the canvas, and the
identity, the current state and the primary action visible at each class.
