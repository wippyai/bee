# Sync integration executable acceptance

The candidate `/tmp/bee-sync-integration-candidate` passed `make standalone`,
`make bundle-check`, `make native-binary-check` and `make native-client-check`.
It is not installed globally. Native remains `a0fc01e088b2`; runtime remains
`674b58a1a117fa79398f723c4311201cca8472e1`.

SHA256: `c653a633549f6f973111e0694cef5b014266727e0e0c17ce7f9baba603dae2f0`.

The integration includes the verified sync/node/inbox source checkpoint from
journal 943. Its full source check passed 508 Lua tests; exact source/pack coverage
was 564 entries. Executable gates additionally prove selected-state node database
initialization, source-free Settings recovery, scrolling/copy, three independent
desktops, observer denial, retained shells and reconnect after client death.
A separate inherited `BEE_NODE_DB` canary remained absent while the selected
`state/node.db` initialized as SQLite. The native fixture now isolates that store.

Evidence logs:
- `/tmp/bee-sync-integration-build.log`
- `/tmp/bee-sync-integration-bundle-check.log`
- `/tmp/bee-sync-integration-native-binary.log`
- `/tmp/bee-sync-integration-native-client.log`
- `/tmp/bee-sync-full-check-final.log` (source lane)

This checkpoint does not fix intermittent mesh startup/detach stalls. Display
appearance inheritance, readable labels, send-to-display and expanded F9 node
roles are subsequent work, not capabilities demonstrated by these gates.

The subsequent `make native-settings-resize-check` passes on this same executable:
three grow/shrink cycles, fullscreen/restore, physical-terminal resize, drag
resize and F12. It checks Settings' footer against the committed body boundary.
It allows up to three seconds to converge and does not prove intermediate-frame
smoothness or reproduce the user's reported resize gap. Evidence:
`/tmp/bee-native-settings-resize-check.log`.
