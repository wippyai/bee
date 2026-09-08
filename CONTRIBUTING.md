# Contributing to Bee

Start with the [agent guide](docs/AGENT_GUIDE.md),
[implemented status](docs/FOUNDATION_STATUS.md), and
[development conventions](docs/DEVELOPMENT.md). The [documentation map](docs/README.md)
separates current contracts from proposals. For community standards, follow the
[Wippy code of conduct](https://github.com/wippyai/.github/blob/main/.github/CODE_OF_CONDUCT.md).

## Development

Use the pinned Go version and native prerequisites in
[native distribution](docs/NATIVE_DISTRIBUTION.md). Install ShellCheck for workflow
validation, then run:

```sh
make native-tools
make check WIPPY="$PWD/.wippy/bin/bee-wippy"
make native-check
make repository-check
```

Run `make lint WIPPY="$PWD/.wippy/bin/bee-wippy"` while editing. Native builds and
packs enforce strict Lua types. Runtime changes need the relevant upstream tests;
desktop changes need source and packed application acceptance. Documentation-only
changes need link and content checks.

Production loads `src/`. Keep fixtures, local stores, credentials and development
tools outside that tree. Preserve protected application admission and typed
boundary decoders. Add migrations without changing already-applied migration files.

## Pull requests

Keep each change focused on one problem. Describe its resulting behavior, the
checks you ran, and remaining limitations. Update implementation documentation
when behavior changes. Main requires CI, a review and resolved conversations;
see the [release protocol](docs/RELEASING.md) for tags and publication.

Bee-owned contributions use [MIT](LICENSE). Preserve upstream license headers in
runtime patches and include dependency notices for new native libraries.
Follow [SECURITY.md](SECURITY.md) for vulnerabilities or exposed credentials.
