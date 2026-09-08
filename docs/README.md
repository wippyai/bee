# Documentation map

The repository Markdown is currently authoritative. Bee does not yet publish a
runtime documentation catalog or agent tools. A future registry catalog should
package these same pages with status and version, not maintain a second copy.

| Read for | Current source |
|---|---|
| Run and develop | [Repository README](../README.md), [agent guide](AGENT_GUIDE.md) |
| What exists and who owns it | [Foundation status](FOUNDATION_STATUS.md) |
| Code style and placement | [Development conventions](DEVELOPMENT.md) |
| App admission, launch, messages and recovery | [Application contracts](APPLICATION_CONTRACTS.md) |
| Database guarantees | [Storage](STORAGE.md), [workspace state](WORKSPACE_STATE.md) |
| Local journal, Test Status and future subscriptions | [Threads](THREADS.md) |
| Package seams and native distribution | [Package boundaries](PACKAGE_BOUNDARIES.md) |
| Current critique and recommended next slice | [Foundation next steps](FOUNDATION_NEXT.md) |

Historical and design references:

- [Platform study](PLATFORM_STUDY.md): source evidence and POC limitations at the study date.
- [Desktop foundation](DESKTOP_FOUNDATION.md) and [local desktop](LOCAL_DESKTOP.md): target architecture, including unimplemented systems.
- [Foundation review](FOUNDATION_REVIEW.md): critique of baseline `ddf6ba8`, before the foundation sweep.
- [UI refinement](UI_REFINEMENT.md): UI design intent; current acceptance tests establish verified behavior.
- [Workspace attachments](WORKSPACE_ATTACHMENTS.md): proposed workspace identity, client layout ownership and local/remote view boundaries.
- [Client/host extraction](CLIENT_HOST_SPLIT.md): current coupling, owner split, appearance scope, migration and acceptance plan.
- [Portable harnesses](PORTABLE_HARNESSES.md): proposed repository-folder and pack execution, headless CI results and selective export.

When these disagree, implemented contracts and their source/tests take precedence
over roadmap prose. Fix the disagreement rather than adding another design page
that silently supersedes it.
