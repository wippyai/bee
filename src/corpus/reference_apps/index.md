# Reference applications

Proven, self-contained Bee application screens for copying: each is a pure
view over `bee.app:frame`, `viz`, `diagram` or `forms` with the model
the application owns, and each is drawn at every size class by
`make reference-apps-check`. Read one, copy it into an application's `view.lua`
and replace the sample data. Overlay and form interaction patterns are in
`overlays` and `deploy_form`.

* `reference_apps/ci_bench`: CI and benchmark board. Demonstrates result history as selectable dashboard cards: candlesticks for latency per commit, a scatter of score against cost, 100% stacked bars of results by suite and a job timeline.
* `reference_apps/deploy_board`: deploy board. Demonstrates a headline row of stat tiles over a run table with a detail pane.
* `reference_apps/deploy_form`: deploy wizard. Demonstrates the input kit inside an application: a wizard strip over one forms.Form per step, focus order and mouse clicks routed through forms.key and forms.click, per-field validation before Next, and a confirmation modal on the last step.
* `reference_apps/inbox`: inbox and approvals. Demonstrates who asked, from which bee, for what and by when: a table of requests with a key-value detail pane for the selected one.
* `reference_apps/log_viewer`: log viewer with a workspace tree. Demonstrates a virtualized log window with search highlighting beside a flattened, already-filtered tree.
* `reference_apps/metrics`: live metrics monitor. Demonstrates stat tiles with sparklines over four cards (line chart, capacity rings, traffic mix, latency histogram).
* `reference_apps/overlays`: command palette, confirmation modal and toast. Demonstrates the overlay stack of an application: one model with a single active overlay, the typed query and choice of the palette (frame.ranked filters and orders the commands), a two-button confirmation and a toast that expires after a number of ticks.
* `reference_apps/topology`: topology and sizes. Demonstrates a mesh of nodes at chosen positions with braille-routed edges and a treemap of sized items (disk by area), as two selectable cards.
* `reference_apps/workflow`: durable workflow. Demonstrates a layered step graph with per-step notes and a flame chart of step durations, as two selectable cards.
