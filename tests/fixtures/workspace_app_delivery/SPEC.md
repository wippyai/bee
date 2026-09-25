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
