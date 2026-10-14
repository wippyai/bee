# bee.executor.external

The permission answer hook for external CLI windows. The namespace holds one
function, `bee.executor.external.binding:answer_hook`, which the Threads
sessions owner calls when a window's CLI delivers a `PermissionRequest` hook
(`hook_http` or `hook_mcp` transport).

The hook accepts only an authenticated session boundary: the caller identity
must be the session and hold `bee.harness.permission.answer`. It re-resolves the
window's admission and refuses when the plan digest changed, the driver or
profile is unavailable, the hook differs from the descriptor's declared answer
transport, or the accepted executable no longer measures as accepted. Windows
whose permission answers are provider-owned, or whose policy declares no
permission exchange, return an empty value.

Otherwise it runs the shared Harness permission exchange
(`bee.harness.permission:exchange`) for the pulled turn, durable Allow/Deny
decisions included, and commits each permission record through
`bee.threads.binding:turn_observation` with an idempotent operation key and the
permission checkpoint.
