# Working on Bee

Start with [the agent guide](docs/AGENT_GUIDE.md) and
[implemented foundation status](docs/FOUNDATION_STATUS.md). The documentation
map is [docs/README.md](docs/README.md). Design proposals are not callable APIs.

Bee-owned code is MIT. Preserve upstream licenses in runtime patches.
Production loads only `src/`; the POC lives outside this repository in
`../bee-legacy/` and must never become a runtime dependency.

Keep core ownership, standalone application processes, explicit typed boundary
decoders and host-selected permissions intact. Registry metadata describes
capabilities; it does not authorize them. Native Terminal has OS-user authority.

Use the Makefile for setup, lint, tests and packaging. Follow
[development conventions](docs/DEVELOPMENT.md) for code organization and checks.
Never edit applied migrations, delete a workspace database to hide a migration
failure, or grant applications direct registry publication to bypass admission.

Update the implementation docs when behavior changes. Keep future agent drivers,
MCP, Hub installation and overlay activation labeled as proposals until their
implementation and acceptance checks exist.
