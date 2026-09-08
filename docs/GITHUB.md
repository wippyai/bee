# GitHub setup

The repository is private during alpha preparation. Its documentation entry point
is [docs/README.md](README.md); no GitHub Pages site is configured.

## Protection and automation

| Setting | Configuration |
|---|---|
| Main | Pull request, one code-owner review, stale approval dismissal, resolved conversations, current base |
| Required checks | `Bee CI` and `Native module CI`, produced by GitHub Actions |
| Administrators | Main protection applies |
| History | Linear; force pushes and deletion blocked |
| Release tags | Creation limited to administrators; updates and deletion blocked for everyone |
| Default Actions token | Read-only; cannot approve pull requests |
| External actions | Full commit SHA required |
| Secret protection | GitHub scanning and push protection enabled |
| Dependencies | Vulnerability alerts and security updates enabled; weekly grouped version updates |

CODEOWNERS names the repository maintainers. Pull requests use local issue and
review templates, [contribution guidance](../CONTRIBUTING.md), and the
[organization code of conduct](https://github.com/wippyai/.github/blob/main/.github/CODE_OF_CONDUCT.md).
See [SECURITY.md](../SECURITY.md) for private reports.

## Credential boundary

`WIPPY_HUB_TOKEN` is an Actions secret in the `hub` environment. Only the Hub
publication workflow references it, as `WIPPY_TOKEN` in the credential check and
publication steps.
The environment permits the `main` branch and `v*` tags, with no manual approval
step. A separate ruleset limits release-tag creation to repository administrators.
PR branches cannot use the environment, and the token has no repository-wide copy.
PR builds and artifact assembly receive no Hub token. The publication workflow
requires a published application release and a successful native tag build at
the same commit. Its GitHub token has `contents: read` and `actions: read`.

`BEE_HUB_VISIBILITY` is an optional repository variable, defaulting to `private`.
It controls first-time Hub module creation; it does not change GitHub visibility.

Checkout steps set `persist-credentials: false`. Write access is limited to
release jobs that create draft releases. The repositories have no deploy keys or
webhooks. No signing key is configured.

## Verification

On 2026-09-08, Gitleaks v8.30.1 found no credentials in 72 reachable commits,
including available PR heads. The scan used default provider rules plus a Wippy
Hub token rule. GitHub secret and dependency alert lists were empty when checked.
These are scan results for the inspected material, not a guarantee against every
possible secret format.

`make repository-check` validates workflows and scans Git history and current
files with redacted output. It is part of the application validation and release gates.
The downloaded platform archives and saved release proof logs also scanned clean.
Direct scans of all four executable payloads found no Wippy or GitHub token patterns.

## Release boundaries

Bee creates draft releases after its required platform checks pass. Version tags
must belong to main and use the documented semantic version format. See
[releasing](RELEASING.md) for artifact contents and publication.

Anonymous installation requires a public release repository. Executable signing
and signed build attestations are not configured. Actual Hub upload and update acceptance
remain part of the first-release verification.
