# Saved Docker profile homes

The runtime pin in `wippy.build.json` is `4caad4761a0c883024c5df27f47d326f0146b41a`.
Its `service/exec/docker/docker.go` says:

> buildBinds prepares Docker short-syntax volume specifications for the daemon.
> Relative host paths are resolved client-side, matching Docker CLI behavior;
> the daemon remains the authority for parsing and validating the full syntax.

`buildBinds` preserves bare named-volume sources. The executor passes its result
as `HostConfig.Binds`; per-process mounts explicitly use `Type: mount.TypeBind`.
Bee therefore derives one named volume from the admitted grant's node, workspace,
and saved-profile identity and puts it in a generated executor's `volumes`.
Revision, launch, session, driver mode, and image identity do not change the volume.

Native `homes.lua` materializes broker files beneath the private attempt root.
Saved Docker launches keep that projection disposable, including retained-session
launches. The named home contains CLI history, sessions, settings and nonsecret
state initializers. Declared state without a source path or write-back is seeded
only if absent. Generated delivery files, login files and source configuration
files use read-only file mounts from the attempt home, including empty protected
login destinations when login is absent. Their underlying volume mount points
contain no secret bytes. No machine home directory is mounted or copied.

Driver `source_path` identifies broker input, `path` identifies the guest destination,
and `write_back` authorizes only the broker's exact login file. Native write-back
reads the attempt home, never the named volume; the pinned no-follow limitation
continues to refuse unsupported write-back. Tokens cannot become persistent
home state through Bee's write-back path.

Profile removal removes the owned volume and its generated executor entries.
Reset is person-only, removes and recreates the volume, and advances the profile
revision. Both refuse outstanding attempts and Docker volume-in-use errors.
A receipt under the placement root identifies volume ownership across Bee restarts.

`bee.tests.placement.docker:home_test` runs the pinned binary against Docker in an
isolated fixture workspace. It issues fake file credentials through the broker,
launches two containers for one saved profile, checks another profile's isolation,
checks token absence by mounting the volume alone, resets, and deletes both profiles.
It also verifies nonsecret state is not reseeded and an intended launch blocks reset.
The focused ownership regression fails against the original implementation with
“container has another provider home mount”.

Validation on 2026-10-15: the focused Docker/profile selection passes 183 cases;
the final ownership, profile-service and profile-view selection passes 42 cases.
Python passes 69 tests. The Docker proof passes with the same binary on both
machines (SHA-256 `b4d1f0ee4b494c9ddff673d0962285c96b3d3c5d00af39fa4749144bb01accc4`).
Both proof volumes are absent after profile deletion. No full check or CI runs.
