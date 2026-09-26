# Tally

Build a Bee desktop application named Tally for this workspace and deliver it
here for my approval.

- Overlay `tally`; the application entry is `app.tally:app`, titled `Tally`.
- The window header reads `TALLY`. The work area shows `Tally: N`, the current
  count, and `Saved: N`, the last count the desktop acknowledged saving.
- Enter or a click on "Add one" adds one. `r` or a click on "Reset" sets the
  count to zero. Esc closes the window.
- Every change is saved as the checkpoint `{"tally": N}`; after a restart the
  window opens with the saved count.
- It draws through the shared application frame and follows the Bee
  application style guide.
- Request the host catalog capability `threads.read` with `scope: owned` using
  a measured `ns.requirement` targeting `app.tally:app` at
  `.security.policies +=`. The grant is reviewed during installation.
- Request the host catalog capability `workspace.files.read` with
  `subpath: shared` using a measured `ns.requirement` targeting
  `app.tally:app` at `.security.policies +=`. At startup call
  `bee.gov.binding:granted_resources` for the granted volume (`volumes.shared`)
  and database (`databases.tally`) identities, then read the workspace file
  `/greeting.txt` through the granted volume; the window never opens without
  it.
- Request the host catalog capability `app.database` with `name: tally`
  using a measured `ns.requirement` targeting `app.tally:app` at
  `.security.policies +=`. Record every count with the greeting as a row in
  the granted database; the rows survive a restart.
- Request the host catalog capability `agents.launch` with
  `definitions: [bee.workspace.app.probe:child]` using a measured
  `ns.requirement` targeting `app.tally:app` at `.security.policies +=`. At
  startup, call the application agents helper's `run` with that definition and
  a brief, then record the returned attempt receipt (attempt id, definition and
  state) as a row in the granted database. The same grant must refuse a
  definition it does not name.
- The application needs the `fs`, `sql` and `agents` helpers alongside the
  interface modules above.
