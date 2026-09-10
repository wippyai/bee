# Foundation synchronization history

## Latest checkpoint: retained desktop resources

`9308a39c55c386ba38d9caf3a89d9389a2779171` is verified on
`feat/independent-view-bindings`. Full `make check` session 97600, standalone
assembly 70185 and native acceptance 11504 exited 0. The supervising actor retains
virtual desktop resources through physical display loss and releases them only
on matching desktop EXIT. It reuses an existing workspace host and rejects a
second store binding in the same supervisor. Exact source/fixture changes are
applied to shared source, with its independently changed acceptance document
merged separately. Public retained desktop activation remains pending. No live
validation sessions. See `DESKTOP_OWNER_EXTRACTION.md` for logs.

## Earlier checkpoint: retained desktop attachments

`4a81c86067e1248f0ee8faa42ab4b68cc76f36c0` is verified on
`feat/independent-view-bindings`. Full `make check`, standalone assembly and native
acceptance pass. The graceful-close regression additionally fails before the fix
and passes afterward in source/pack for both appearance modes. Exact source and
fixture changes are applied to shared source; its unrelated manifest remains
unchanged. Public retained-desktop launch is still pending. See
[desktop owner extraction](DESKTOP_OWNER_EXTRACTION.md) for the evidence and
remaining ownership boundary. No live validation sessions remain for this slice.

## Observer follow-up synced

`57e85976fe32afcadbc528aab0fada2a4862197c` is pushed and verified on
`feat/independent-view-bindings`. The isolated worktree is clean. The full
`make check` session 19056 completed successfully: 118 unit tests and all
source/pack gates, including a 320 ms 16-window shutdown. Standalone assembly
and native acceptance passed as recorded below. No PR/main update was made.

`/tmp/bee-observer-upstream-20260909` starts at `2dea2eb` and contains the
observer/protocol/host/presenter-delivery changes plus their focused fixtures.
It excludes Hive, harness and experimental module-root work. Copied input hashes
are in `/tmp/bee-observer-upstream-inputs.json`. The upstream-only runtime is
`/tmp/bee-foundation-sync-20260909/.wippy/bin/bee-wippy`.

Strict production lint, all 118 unit tests, `make attachments-check` and
`make client-desktop-check` pass, including source/pack observer and controller
continuity. Logs: `/tmp/bee-observer-upstream-unit-check.log` and
`/tmp/bee-observer-upstream-attachments-check.log`.
Full `make check` passed; log `/tmp/bee-observer-upstream-full-check.log`.
Standalone build session 94979 and native acceptance session 74904 both ended
successfully. Logs: `/tmp/bee-observer-upstream-standalone.log` and
`/tmp/bee-observer-upstream-native-check.log`. Synced implementation
docs now cover bounded delivery and observer permissions, keeping public remote
selection and node-owned desktop activation explicitly pending.

## Synced committed foundation

Completed checkpoint: `2dea2eb62cc234d71054ae18c6d02bb79a3881c0`, pushed and
verified on `feat/independent-view-bindings`. No PR was opened or merged; main
was not changed. The isolated worktree is clean. The full `make check` session
22018 ended successfully, including all 115 unit cases and source/pack gates.
Standalone build and the expanded native acceptance also pass. The notes below
retain how the candidate was assembled; their pending steps are now completed.

The shared checkout's committed host/client foundation and published main
diverged at `c2b43fc`. Published main `93cbc0a` contains the upstream-only runtime
and builder cutover, but lacks the 22 local commits through `722729c`.

The candidate was assembled in `/tmp/bee-foundation-sync-20260909` from
`722729c` by merging published main. The only textual conflict was in
`tests/architecture.py`: the result preserves host/client namespaces and selects
`.wippy/bin/bee-wippy`. The merge is committed as `2dea2eb`; that worktree is no
longer an uncommitted candidate.

Setup used Wippy `fdad09ce` and Builder `67a0435`, with no runtime patches.
Setup log: `/tmp/bee-foundation-sync-setup.log`. The completed full-gate log is
`/tmp/bee-foundation-sync-check.log`; do not treat its historical session as a
pending job. Standalone evidence is in
`/tmp/bee-foundation-sync-standalone.log` and
`/tmp/bee-foundation-sync-native-check.log`.

The native fixture retains coverage of all four default apps and adds the Test
Status view-close/background completion/reopen/F12/cold-restart idempotency proof.
Shared subsystem mappings and experimental module roots were excluded. Observer
and presenter delivery changes were subsequently synced in `57e8597` above.
Hive, harness and module extraction remain separate lanes.

The checkpoint branch is `feat/independent-view-bindings`. Check its actual remote
head before each normal fast-forward push. Main is protected; no PR was opened
or merged, and no protection bypass is authorized.
