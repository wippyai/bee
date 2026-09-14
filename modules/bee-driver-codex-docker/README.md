# wolfy-j/bee-driver-codex-docker

This optional component adds one Codex window profile backed by Bee's existing
Docker placement binding. It owns a launch definition, launch policy and the
small binding/profile declaration that selects Docker's retained private HOME.
That binding delegates to the existing Codex prepare, dispatch, normalize and
configure methods. The Agent picker, thread, gateway, credential, resource and
Docker lifecycle contracts stay with their existing components.

The installing host must provide both package requirements:

- `image`: the full immutable `sha256:` image ID of a locally available image
  containing Codex at `/usr/local/bin/codex`.
- `user`: the non-root numeric `uid:gid` used inside that image.

The profile mounts the already admitted `project` resource at `/workspace`,
uses a private retained HOME at `/home/bee`, and asks the existing credential
broker for the optional `codex_login` projection. It does not inherit host HOME,
discover Docker, mount the daemon socket, create a second profile schema, or
own container lifecycle state.

The container uses an explicitly selected Docker bridge and the existing Bee
gateway binding. The host must configure Bee's gateway listener on an admitted
private interface reachable from that bridge. Bee still chooses a random port,
requires exact Host checks, and scopes MCP and hook tokens to the attempt. A
loopback-only gateway makes real container launch unavailable; this component
does not weaken that boundary with host networking or synthetic hostnames.

The component is outside Bee's default `src/` pack. A local immutable Codex
0.154.0 image passes the real managed-picker, PTY, retained-HOME, credential,
MCP and removal acceptance without a model turn. The manifest still claims no
distributable production image or publication until its package dependencies
and image artifact are published and pinned.
