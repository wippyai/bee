# Contributing to Bee

Read the [repository README](README.md), [agent guide](docs/development/agent-guide.md),
[development conventions](docs/development/conventions.md), and [documentation map](docs/README.md)
before making changes. Follow the [Wippy code of conduct](https://github.com/wippyai/.github/blob/main/.github/CODE_OF_CONDUCT.md)
for community standards.

## Development

Use the pinned Go version and native prerequisites in
[native distribution](docs/operations/native.md). Install ShellCheck for
workflow validation, then run:

```sh
make native-tools
make check WIPPY="$PWD/.wippy/bin/bee-wippy"
make native-check
make repository-check
```

Run `make lint WIPPY="$PWD/.wippy/bin/bee-wippy"` while editing. Native builds
and packs enforce strict Lua types. Runtime changes need the relevant upstream
tests; desktop changes need source and packed application checks. Documentation
changes need link and content checks.

Production loads `src/`. Keep fixtures, local stores, credentials and development
tools outside that tree. Preserve protected application admission and typed
boundary decoders. Add migrations without changing already-applied migration files.

## Pull requests

Keep each change focused on one problem. Describe the resulting behavior, checks
run, and remaining limitations. Update implementation documentation when
behavior changes. Main requires CI, a review, and resolved conversations; see the
[release protocol](docs/operations/releasing.md) for tags and publication.

Bee-owned contributions use [MIT](LICENSE). Preserve upstream license headers in
runtime patches and include dependency notices for new native libraries.
Follow [SECURITY.md](SECURITY.md) for vulnerabilities or exposed credentials.
