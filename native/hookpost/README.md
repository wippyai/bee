# Native hook POST

`bee hook-post ENDPOINT ACTION_ID TOKEN_ENV_OR_FILE EVENT` is the generated
command-hook entry. It runs before project selection, workspace state or Hive
startup. The host selects this executable; the gateway still authorizes the
submitted token. The helper has no registry, database or thread authority.

`TOKEN_ENV_OR_FILE` accepts the existing environment-name form and the private
file form `@/absolute/path/to/token.json`. A file source must be an absolute
path of at most 4096 bytes to one JSON object of exactly `{"token":"..."}`;
the file is limited to 8192 bytes and the token to 4096 bytes. It is checked as
a regular, non-symlink file both before and after opening; directories,
symlinks, oversized files and malformed or oversized tokens are refused.
Selecting `@...` never falls back to an environment variable, and errors do not
disclose the path or token.

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

`make -C native test` runs the helper's tests, including a real pipe read
cancellation, stalled peer and redirect refusal, and the launch host's routing
of `bee hook-post` before project selection and the client route.
