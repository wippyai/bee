# Capability model

The pure `bee.capability:model` library decodes the host catalog, resolves
capability requests, compares grant scopes, and builds revocation reports.
Governance, Resources, and Gateway keep their own grant records and storage.

Catalog meanings do not grant authority. Each owner checks and records grants
under its host-selected permissions.
