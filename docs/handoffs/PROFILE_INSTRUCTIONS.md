# Profile instruction functions

Source `d829724` adds an optional host-policy `instruction_builder` containing a
function identifier and JSON arguments. It supplements static profile guidance;
an empty result leaves existing guidance alone. It never replaces a harness's
built-in system prompt or the turn prompt.

The runtime supplies the authenticated actor and `ctx`. The builder receives an
empty inherited scope, with resource access granted only by its own policies.
The selected identifier and arguments are measured in the configuration digest.
The function's implementation is not pinned by that digest. A committed placement
intent stores validated instruction delivery, so retries after commit do not
evaluate the function again; a retry before commit may do so.

Validation on the source merged with the offline global build: strict lint and
796 unit cases pass (`instruction-builders-integrated-check.log`, session17771).
The native placement fixture checks actor/context, declared reads, denied store
and execution access, and the actual private-home instructions file. It then
replaces the builder with a failing function, proves the replacement is live,
and verifies that the committed receipt replays with byte-identical delivery.
Driver checks cover empty results, static/dynamic append, errors and bounds.
Luna's independent review found no concrete authority or replay defect.

This is launch-time host configuration. The picker does not yet edit this field,
and active CLI sessions do not refresh it per turn. Global SHA `1b56f795`
includes this feature, with native launch and offline restart/reconnect checks;
see `GLOBAL_BUILD.md`. Managed Docker, automatic Agy login and authenticated provider
orchestration remain separate work.
