# Bee UI brand book

Bee is a compact desktop for people and agents working together. Its interfaces
should feel calm, precise and a little playful: dark work surfaces, warm honey
focus, sparse texture and information that becomes more detailed only when the
window has room. The `Honey` appearance is the canonical expression of the
brand; every other appearance preserves the same semantic roles.

The runnable reference is **UI Guide** under **Tools → Learn**. Its source is
`src/apps/stylebook/`. Application authors should copy its process/view split,
resize behavior and interaction shapes rather than its literal sample content.

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

Color expresses interaction, not business state. Write `Ready`, `Waiting`,
`Failed` or `Needs review`; do not make red or green the only carrier of meaning.
One screen should normally have one accent selection and one primary action.
Instance accents belong to window chrome and do not recolor application content.

## Type, spacing and hierarchy

The terminal supplies the monospace typeface. Design in cells.

- Keep one blank cell at the left and right edge of content. Start ordinary
  content at column 2.
- Use a single dense header row. Uppercase the short product or surface name;
  keep descriptions in sentence case.
- Separate major regions with one blank row or a `border` rule. Avoid boxes
  around every value.
- Prefer 1, 2, 4 and 6-cell gaps. A control label includes its own surrounding
  spaces, such as `" Run "`.
- Put the changing status on the penultimate row and stable key help on the
  final row. In short windows, retain the status and the action that lets the
  user recover.
- Truncate by display width with `tty.text.truncate(..., "…")`. Byte slicing is
  only suitable after a bounded, sanitized identifier has been deliberately
  reduced.

## Page anatomy

Every application frame follows the same reading order:

1. **Identity:** title at the upper left; a concise live summary may align right.
2. **Navigation:** selected tabs use accent background plus
   `appearance.selection_text(theme)`; inactive tabs use `muted` on `surface`.
3. **Work:** lists, forms, metrics or a focused detail. Selection uses the same
   accent pair as tabs.
4. **Feedback:** explicit empty, loading, success or error text in a stable row.
5. **Actions:** visible keys use the same verbs as mouse controls.

Use progressive disclosure. A narrow window keeps identity, selection, the main
value and one action. Wider windows may add metadata, a side rail or detail pane.
Technical IDs belong in detail views unless they are needed to distinguish two
rows. Never horizontal-scroll a primary workflow.

## Controls

Tabs and segmented controls are short labels with padded hit areas. Buttons use
`accent` text on `surface` until focused or selected; selected controls reverse
to `selection_text` on `accent`. Disabled controls remain visible in `muted` and
must not have an active hit target.

List and table rows use the whole visible row as their mouse target. Keep a
stable identity when rows refresh. On compact widths, turn columns into a
primary label plus a short `·`-separated summary rather than clipping every
column independently.

Forms put the label before the value and keep errors next to the affected work.
Confirmation text names the effect and the two choices, for example
`Stop selected app? Enter confirms · Esc cancels`. Destructive work always has
an explicit confirmation state.

## States

- **Loading:** say what is loading. Keep navigation responsive.
- **Empty:** say what is absent and give the next useful action.
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

Focus must be visible without color perception: selected rows keep their text,
controls keep their label, and state words remain present. Test Honey plus one
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
- A permanent legend that consumes several rows when one footer will do.
- Borders around every region, decorative gradients or shadow-like glyph noise.
- A wide table merely clipped on narrow screens.
- Status conveyed only by color, icon or animation.
- Remote calls, filesystem work or polling inside `view.draw`.
- Rendering user, agent, node or package text without bounding and sanitizing it.
- Creating a generic widget framework before two real applications share the
  same behavior. Keep views pure and extract only proven common operations.

## Authoring checklist

Before delivery, verify that the app uses semantic appearance roles, repaints on
resize, has bounded external text, supports keyboard and mouse, preserves a
useful compact state, keeps remote work out of rendering, and has focused tests
for the user-visible behavior. Run `make lint`, the focused view tests, the
source application journey and `make pack` when the application contract or
production registry changed.
