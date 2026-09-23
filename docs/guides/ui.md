# Bee UI brand book

Bee is a compact desktop for people and agents working together. Its interfaces
should feel calm, precise and a little playful: dark work surfaces, warm honey
focus, sparse texture and information that becomes more detailed only when the
window has room. The `Honey` appearance is the canonical expression of the
brand; every other appearance preserves the same semantic roles.

Every Bee application, bundled or agent-built, draws through the shared
application frame, `bee.application:frame`. The exact placement, color, state
and breakpoint rules, with one layout per application archetype, are in
[Application visual style](app-style.md); read it before drawing. The runnable reference is **UI
Guide** under **Tools → Learn**; its source is `src/apps/stylebook/` and it
demonstrates every frame component. Application authors should copy its
process/view split, resize behavior and interaction shapes rather than its
literal sample content.

## Semantic palette

Use `bee.application:appearance`; never embed the Honey hex values in an app.

| Role | Honey | Use |
|---|---:|---|
| `ground` | `#0c1119` | Desktop behind windows |
| `surface` | `#17202c` | Application body and panels |
| `text` | `#d8e2ef` | Primary content |
| `muted` | `#8999ad` | Labels, metadata, hints and disabled controls |
| `border` | `#6f89a5` | Rules, outlines and passive separation |
| `accent` | `#ffc963` | Focus, selection and the primary action |
| `pattern` | `#1c2937` | Quiet desktop texture |
| `selection_text(theme)` | derived | Text drawn on `accent` |
| `ok` | `#7ee787` | A success word; data inside a healthy range |
| `warn` | `#ffa657` | An attention word; data past a warning threshold |
| `error` | `#ff7b72` | A failure word; an inline field error; data past a failure threshold |

Accent expresses interaction. The status roles `ok`, `warn` and `error` repeat
a meaning that words or numbers in the same row already carry: write `Ready`,
`Waiting`, `Failed` or `Needs review`, and never make red or green the only
carrier of meaning.
One screen should normally have one accent selection and one primary action.
Instance accents belong to window chrome and do not recolor application content.

## Type, spacing and hierarchy

The terminal supplies the monospace typeface. Design in cells.

- Keep one blank cell at the left and right edge of content. Start ordinary
  content at column 2.
- Use a single dense header row (`frame.header`). Uppercase the short product or
  surface name; keep descriptions in sentence case. A live summary aligns right
  in `muted` and gives way to the title when space runs out.
- Separate major regions with one blank row or a `border` rule. Avoid boxes
  around every value.
- Prefer 1, 2, 4 and 6-cell gaps. A control label includes its own surrounding
  spaces, such as `" Run "`.
- Put the action bar on the penultimate row (`frame.actions`) and the footer on
  the final row (`frame.footer`): the changing status at the left, the stable
  key hints at the right. In short windows the status wins the row; keep the
  action that lets the user recover.
- Write key hints as key then lowercase verb, joined with ` · `
  (`frame.hints`): `↑↓ select · Enter open · Esc close`.
- Truncate by display width with an ellipsis; every frame call does this. Byte
  slicing is only suitable after a bounded, sanitized identifier has been
  deliberately reduced.

## Page anatomy

Every application frame follows the same reading order:

1. **Identity:** title at the upper left; a concise live summary may align right
   in `muted`.
2. **Navigation:** `frame.tabs`. Selected tabs use accent background plus
   `appearance.selection_text(theme)`; inactive tabs use `muted` on `surface`.
3. **Work:** lists (`frame.row`), tables (`frame.table`), forms, metrics or a
   focused detail. Selection uses the same accent pair as tabs and a `›` marker
   in column 1.
4. **Actions:** the penultimate row. Visible keys use the same verbs as mouse
   controls.
5. **Feedback:** the final row: explicit status text at the left, key hints at
   the right. Empty, loading and error states in the work area use
   `frame.empty`.

Use progressive disclosure. A narrow window keeps identity, selection, the main
value and one action. Wider windows may add metadata, a side rail or detail pane.
Technical IDs belong in detail views unless they are needed to distinguish two
rows. Never horizontal-scroll a primary workflow.

## Controls

Tabs and segmented controls are short labels with padded hit areas. Buttons use
`accent` text on `surface`; the one primary action and selected toggles reverse
to `selection_text` on `accent` (`primary` and `active` on `frame.Button`).
Disabled controls remain visible in `muted` and must not have an active hit
target.

List and table rows use the whole visible row as their mouse target. Keep a
stable identity when rows refresh. Tables align their columns and right-align
numbers; on compact widths `frame.table` turns columns into a primary label plus
a short `·`-separated summary rather than clipping every column independently.

Forms put the label before the value and keep errors next to the affected work.
Confirmation text names the effect and the two choices, for example
`Stop selected app? Enter confirms · Esc cancels`. Destructive work always has
an explicit confirmation state.

## States

- **Loading:** say what is loading. Keep navigation responsive.
- **Empty:** say what is absent and give the next useful action on the row
  below it (`frame.empty`); do not repeat it as a status.
- **Waiting:** name the owner, such as `Waiting for approval`.
- **Success:** name the completed effect; do not rely on a transient flash.
- **Failure:** retain the user's context and describe a recovery action.
- **Unavailable:** distinguish missing capability from a slow or disconnected
  owner. Remote work must never block input or painting.

Animated progress is optional. Honor a static presentation when motion adds no
information, and never use animation as the only evidence that work continues.

## Input and accessibility

Every mouse action has a keyboard route. Arrow keys move within a collection;
Tab changes panes; Enter performs the selected primary action; Escape backs out
or closes. Ignore key-release events. A resize repaints from model state and
must not trigger remote work.

Treat all external text as hostile presentation data. Pass it through
`bee.application:text.bound`, replace controls, set a byte ceiling at the
decoder, and then truncate by terminal display width. A rendered row must always
occupy exactly the current canvas width. Do not place raw ANSI from a remote
source into a styled run.

Focus must be visible without color perception: selected rows keep their text
and carry the `›` marker, controls keep their label, and state words remain
present. Test Honey plus one
light theme and Windows Classic because each stresses a different contrast
assumption.

## Responsive acceptance

For a pure `view.draw`, test at least widths `1, 20, 40, 80, 120` and heights
`1, 6, 12, 24`. Require the exact number of rows, the exact display width for
every row and every hit rectangle to remain inside the canvas. Check the narrow
frame still exposes identity, current state and a usable route forward. Then run
one real application test that resizes while focused and proves keyboard input
continues afterward.

## Patterns to avoid

- Raw hex colors or a private theme table inside an application.
- Private copies of header, button, row, table, footer, sparkline or chart
  drawing; use the frame and `bee.application:viz`.
- Accent on text that is neither focus, selection, the primary action nor the
  primary chart series.
- A status role on a whole row, a background, a border or a title.
- A permanent legend that consumes several rows when one footer will do.
- Borders around every region, decorative gradients or shadow-like glyph noise.
- A wide table merely clipped on narrow screens.
- Status conveyed only by color, icon or animation.
- Remote calls, filesystem work or polling inside `view.draw`.
- Rendering user, agent, node or package text without bounding and sanitizing it.
- Adding to the frame what only one application needs. Keep views pure and
  extract only operations several applications share.

## Authoring checklist

Before delivery, verify that the app draws through `bee.application:frame`, uses
semantic appearance roles, repaints on resize, has bounded external text, supports keyboard and mouse, preserves a
useful compact state, keeps remote work out of rendering, and has focused tests
for the user-visible behavior. Run `make lint`, the focused view tests, the
source application journey and `make pack` when the application contract or
production registry changed.
