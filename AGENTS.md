# Working on Bee

Read the [repository README](README.md), [agent guide](docs/development/agent-guide.md),
[development conventions](docs/development/conventions.md), and [documentation map](docs/README.md)
before changing the project. Production sources live in the root and selected
modules' `src/` directories; tests and build tooling are not shipped. The POC in
`../bee-legacy/` is reference material and must never become a runtime dependency.

Bee-owned code is MIT. Preserve upstream licenses in runtime patches. Keep core
ownership, standalone application processes, explicit typed boundary decoders,
and host-selected permissions intact. Registry metadata describes capabilities;
it does not authorize them. Native Terminal has OS-user authority.

Use the Makefile for setup, lint, tests, and packaging. Run `make lint` while
editing and `make check` for behavioral changes. Never edit applied migrations,
delete a workspace database to hide a migration failure, or grant applications
direct registry publication to bypass admission.

Keep implementation documentation aligned with source and tests. Describe only
implemented operations as callable; label unfinished designs as proposals.

Follow the module roles in the development conventions. Do not invent
workflow-stage namespaces or forwarding wrappers merely to distribute files
across directories.
