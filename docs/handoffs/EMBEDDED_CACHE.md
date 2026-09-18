# Embedded cache lane

Local implementation and executable proof are complete. GitHub publication is
pending; the user reported 90% Actions quota usage, so all checks stayed local.
Do not describe this feature as released or merged upstream.

Runtime branch `/tmp/runtime-cache-seed`, `feat/application-cache-seed`, commit
`0554e488a5609d5d3b459749dfbd3eb91f7b9b03`, adds immutable cache seeds, validated
lint export, strict application host policy and writable-cache reuse across
staged updates. Request Rodrigo (`skhaz`) review before merging it.

Builder branch `/tmp/builder-cache-seed`, `feat/embedded-cache`, commit
`cd304ef0857568c0fa690f0bfc9e36d31f3f62f6`, validates the exact application with
runtime lint, embeds the cache and relinks. It includes executable cache/strict
type acceptance in the existing offline CI gate.

Bee integration `/tmp/bee-cache-integration`, `feat/embedded-cache`, commit
`0791075eea169acaf830c871e6ebf283ef0a59ee`, updates both workflow Builder pins,
the bootstrap lock, runtime pin and distribution docs. It is based on published
main `93cbc0a860a77ba77f5cc2f014f0d3c8e7585f2e`. The shared native manifest,
runtime experiments, source, Hive and UI work were preserved.

The final binary and archive are under `dist/release-local/embedded-cache/`.
`PROOF.md` there records exact hashes, commands/sequence, raw timing and test logs,
and review diffs. Final first-desktop timing: 335 ms median, 323–478 ms across five
fresh-state launches, zero writable Lua cache files. The OS page cache was not
flushed. Offline Docker acceptance passed all default apps, Settings recovery,
Terminal and F12. The local Hub fixture passed update, unchanged cache on first
updated boot, base recovery and failed-update preservation.

Next integration steps: publish runtime for review, publish dependent Builder and
Bee changes, run the required GitHub platform checks when quota permits, and then
advance release pins. No branch was pushed and no release or Hub upload occurred.
The user's installed Bee remains unchanged.
