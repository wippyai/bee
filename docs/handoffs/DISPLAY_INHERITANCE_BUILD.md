# Display inheritance candidate

This candidate is not installed. The global executable is unchanged.

Implemented in the isolated display-inheritance checkpoint:
- Ordinary Settings writes are display-local; applications use their controller's palette.
- Fresh displays inherit node defaults. Existing v1 layouts preserve choices as custom overrides.
- Use node default resumes inheritance; node metadata permission cannot change defaults.
- Host notification authorization rejects observers and stale client identities.

Verified: client-desktop-check source/pack (session 98792), including all retained
supervisor variants; host/client Wippy tests (28 cases, session 66808).
The broker-only predecessor cd2f9da passed full make check and is pushed.

In progress:
- Full combined check: session 31021, /tmp/bee-display-inheritance-full-check.log.
- Local launcher: session 42733, /tmp/bee-display-local-launcher-r2.log.
  The first run passed normal source/pack launch and failed the legacy injected
  workspace-write failure case because ordinary launch no longer grants it.
  The revised fixture explicitly selects that legacy grant for that case only.
- Executable build: session 64522, /tmp/bee-display-inheritance-build.log,
  output /tmp/bee-display-inheritance-candidate. Runtime pin unchanged.

After successful build and source checks, run native-binary-check,
native-client-check and bundle-check against this artifact before global install.
The user explicitly requested global installation and previously authorized
restarts. Preserve databases; existing processes retain loaded code until restart.

Still unfinished: visible inherit/custom status, keyboard reset, node-default
editor, friendly labels, display browsing/transfer, expanded F9 node roles,
intermediate resize frames and intermittent mesh startup/detach diagnosis.

## Independent Settings correction

The first executable passed native-binary and native-client checks, but a new
real two-display Settings probe reproduced an expired mount after the second
display opened Settings. Settings was a workspace-wide singleton; its open reused
the first display's application. Settings now uses the existing multiple-instance
policy, giving each open its own application. This is not a runtime change.

The original full check and corrected build stopped without a completion receipt;
their process handles were missing and no matching process remained. The r2
artifact was absent. Current runs: full check session 38048,
`/tmp/bee-display-inheritance-full-check-r2.log`; build session 10605,
`/tmp/bee-display-inheritance-build-r2-resumed.log`.
Local launcher r2 completed successfully before the interruption.
The global binary remains unchanged pending the corrected executable proof.

The corrected executable built successfully: SHA256
`a19eb6ff8a42ed15806c11a38505075709e512bab26007e25c9da20fc123032a`.
`make native-display-appearance-check` passed (session 6147), proving two open
Settings instances: primary inherit → custom Classic → F12 → reset Honey,
while the sibling stays inherit/Honey. Log:
`/tmp/bee-display-inheritance-native-appearance-r2.log`.
Final executable gates are running: native-binary 72490, native-client 38685.

Corrected executable gates passed: native-binary 72490, native-client 38685,
and native-settings-resize 5306. Resize proves final footer alignment through
physical/window grow/shrink, restore and F12, with the existing three-second
convergence allowance; it does not prove every intermediate drag frame.
Full source check 38048 remains live; global installation still pending.

## Full-suite cleanup correction

The final-source r2 check stopped at 510/511 Lua cases. The only failure was
`Gateway through the carrier > lets a replacement replay rows the original
committed but never acknowledged, leaving one observation`: cleanup asserted
that terminating the resumed fenced carrier returned true. The carrier can exit
on its own before cleanup. The test now requests termination and keeps the
existing bounded monitored-EXIT wait, nil-outcome assertion and exactly-once
record assertions. No production source or executable changed.

Full check r3: session 48370, `/tmp/bee-display-inheritance-full-check-r3.log`.
The committed production checkpoint is e108a4c, pushed to
`checkpoint/display-inheritance-20260910`; no PR or merge was created.
