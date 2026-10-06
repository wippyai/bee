# bee.env

Host resources the other components link to.

| Entry | Content |
|---|---|
| `bee.env:workspace_root` | `fs.directory` rooted at the project folder the node runs in |
| `bee.env:machine_home` | The machine user's `HOME`, read-only |
| `bee.env:machine_login_source` | Read-only (`0500`) `fs.directory` over the machine home; the source of a driver's ambient login files |
| `bee.env:docs_corpus` | Read-only `fs.directory` over `src/corpus`, the offline documentation the `docs` tool reads |
| `bee.env:approved_driver_admission` | `ns.requirement` selecting `bee.gov.binding:driver_bindings` as the admission `bee.harness.launch:harness_activation` reads, so drivers a person approved through an overlay activate beside the host's own |
| `bee.env:approved_driver_logins` | `ns.requirement` selecting `bee.gov.binding:driver_logins` as the admission of `bee.credentials.env:credential_sources`, so an approved driver may use the machine login for its own provider |

Metadata on these entries grants nothing; access comes from the policy the
consuming component holds.
