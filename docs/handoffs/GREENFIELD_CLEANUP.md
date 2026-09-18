# Greenfield cleanup evidence

Global Bee currently contains the display-only appearance change, checkpoint
3d8ac5d, installed SHA ac0871a31007c4638c84d9e6836d512750e1ebdbbd1447eb96adfa626424416b.

Subsequent source changes remove the old combined workspace actor and launch
entry. Their historical implementation lives only in the upgrade test fixture;
production contains workspace persistence and recovery libraries. Source/pack
architecture passes at 567 entries and explicitly rejects reintroducing those
actors. Public migration source/pack preserves data and applied migration history.
The launcher acceptance log is /tmp/bee-combined-removal-launcher.log.

Process Manager now reads heap_alloc directly. The exact runtime pin674b58a1
exports this field; the older alloc fallback is removed. Missing/invalid values
still produce unavailable metrics. Focused source/pack proof is running at
/tmp/bee-process-stats-cleanup-check.log.

Full cleanup check session75112 is running at /tmp/bee-greenfield-full-check.log;
it started before the final one-line Process Manager simplification, which has
its own focused check. The previous inheritance remainder session73168 remains
separate evidence, not acceptance of the current cleanup tree.

Promptmap refine scanned384 files; a narrower unused-code query scanned332 Lua
files. Suggestions to remove permissions, migration integrity, recovery and
schema checks were rejected. Narrow suggestions for the clipboard import,
thread identity/store helpers and stale-status handling had verified live uses.
This is candidate triage, not proof that every dead path has been removed.

Still open: full cleanup acceptance, repack/rebuild of subsequent changes,
friendly labels, node/workspace/display browsing and transfer, explicit Settings
mode visibility and keyboard reset, and sustained mesh recovery verification.
