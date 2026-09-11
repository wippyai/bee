# Display reliability acceptance

Current worktree: `checkpoint/greenfield-cleanup-20260910`.

The release outcome is prompt local/Hive join, independent physical displays,
applications retained across detach/crash, and accurate Hive/node/workspace/display
status. Bee consumes native mesh; this lane adds no runtime ingress or remote
monitor subsystem. Runtime changes belong to the runtime lane and its PRs.

## Current evidence

- Installed SHA `49aa3547f52c0f7db49aa680594327c4d3a4ce1a20875e85477cd84be219942d`.
- User reproduced expired mount followed by detach timeout. Still unresolved.
- Subsequent actual-user smoke joined in 227 ms and detached in 67 ms. One passing
  attempt does not establish sustained reliability.
- Retirement source passes lint, all 512 Lua tests and Hive Manager source/pack
  app checks. Not installed. Only departed presentation rows are retired after
  60 seconds of complete membership absence; saved layouts/apps are preserved.

## Parallel investigations

- Agy, Gemini 3.8 Flash High: read-only attachment/revocation lifetime trace.
- Grok 4.6: read-only retirement semantics review.
- Luna High: bounded disposable-state multi-client crash/rejoin reproduction.
- Primary agent: verify findings, integrate minimal fixes, run release acceptance,
  then install a tested global candidate and record exact artifact identity.

No extra UI polish is needed to close the attachment reliability gate. A fix must
prove simultaneous independent displays, retained application identity, prompt
normal detach, bounded failed detach and reconnect without stale control grants.
A 60-second allowance for flaky node discovery is not permission to delay an
already available local join. Saved layouts and application databases must survive.
