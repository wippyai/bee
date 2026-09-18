# Native hook POST

`bee hook-post ENDPOINT ACTION_ID TOKEN_ENV EVENT` is the generated command-hook
entry. It runs before project selection, workspace state or Hive startup. The
host selects this executable; the gateway still authorizes the submitted token.
The helper has no registry, database or thread authority.

It reads one JSON object, adds the selected `hook_event_name`, and submits once
to the existing loopback hook endpoint. Input and encoded output are limited to
32 KiB. A two-second deadline includes stdin and HTTP. Redirects and proxies are
disabled. Only HTTP 200/202 succeed; intake acceptance is not thread commitment.
The response body is never forwarded, stdout stays empty, and errors contain no
payload, credentials or gateway body. The helper never retries an uncertain
submission and never returns a harness permission decision.

The `bee.harness.host:environment` storage exposes `self`, the executing Bee's
absolute path, for host-selected configuration. This keeps generated callbacks
on the current executable instead of finding another Bee through PATH.

`make -C native hook-post-check MESH_RUNTIME=/reviewed/runtime/checkout` runs
race tests and vet with temporary module resolution. It includes a real pipe
read cancellation, stalled peer, redirect refusal and routing before owner startup.
