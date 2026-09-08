# Security

Report suspected vulnerabilities privately to [support@wippy.ai](mailto:support@wippy.ai),
the contact listed in the [Wippy community policy](https://github.com/wippyai/.github/blob/main/.github/CODE_OF_CONDUCT.md).
Include the affected version or commit, a minimal reproduction, and the expected
impact. Remove credentials and personal data from attachments. Wait for a
coordinated disclosure before opening a public issue with exploit details.

Bee is in alpha. Fixes target the current main branch and the next release;
there is no long-term support policy yet.

## Credentials and releases

Store deployment credentials in GitHub Actions secrets or your local credential
store. Do not put them in manifests, application packs, logs, screenshots, or
release archives. If a credential is exposed, revoke it at its issuer before
replacing the stored secret; deleting the committed file does not revoke it.

Pull request checks receive no Hub credential. Bee keeps its Hub token in an
environment restricted to main and release tags; only administrators can create
those tags. Environment access is automatic for those refs. Workflows default to read-only
GitHub permissions, and release jobs request write access explicitly. Actions
use full commit pins. Repository checks scan Git history and current files with
Gitleaks, including a rule for Wippy Hub tokens. Scanner output is redacted.

Release checksums detect corrupted downloads. The current alpha pipeline does
not sign executables or produce signed build attestations.
