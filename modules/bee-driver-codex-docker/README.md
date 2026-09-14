# wolfy-j/bee-driver-codex-docker

This optional component adds one Codex window profile backed by Bee's existing
Docker placement binding. It owns only a launch definition and its launch
policy. The Codex driver, Agent picker, thread, gateway, credential, resource
and Docker lifecycle contracts stay with their existing components.

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

The component is outside Bee's default `src/` pack. Its manifest does not claim
a runnable production image or publication until the driver and Docker package
dependencies are pinned and the immutable Codex image passes the full managed
Agent acceptance.
