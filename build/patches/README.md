# Runtime patch composition

Bee builds from runtime PR
[#789](https://github.com/wippyai/runtime/pull/789), on top of the application
model in [#787](https://github.com/wippyai/runtime/pull/787), at the exact
commit recorded in `wippy.build.json`.

`runtime-terminal-session-identity.patch` is the sole remaining composition. It
preserves the optional host process identity after PTY ownership transfers to a
terminal session. `TerminalSession:pid()` returns an optional integer and an
optional error; startup remains asynchronous, with a retryable unavailable
result until it completes. A PID is not proof that a process group has exited.

The manifest verifies the patch digest before applying it. Upstream MPL-2.0 file
licenses remain unchanged. The affected terminal and exec race suites and Go vet
must pass before the patch or runtime pin changes.
