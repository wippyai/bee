# Dependency notices

Release artifacts include the applicable notices for Bee, the linked runtime
and bundled native sources. Bee-owned code and artwork are MIT. Runtime patches
retain their upstream license, and native third-party notices are kept in
THIRD_PARTY_NOTICES.md.

Before publishing an artifact, generate its dependency inventory from that
artifact's Go build metadata and collect the root license documents for linked
modules. Review each target independently: a notice present in one executable
does not establish the notice set for another target.

Do not infer a dependency's license from Bee, Wippy or a neighboring module.
Resolve the applicable terms for the selected pinned inputs before public
distribution. Keep license sources and notices with the release material; do
not put credentials, local databases or private build paths in release assets.

The native dependency and archive checks are part of the release procedure in
[Releasing](releasing.md). For local native validation run:

    make -C native test
    make -C native patched-check
