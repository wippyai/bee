# Production architecture checker

The Go checker audits the declared `src/` registry graph and then compares the
source and packed runtime inventories. Run it from the repository root with:

```sh
make architecture-check WIPPY=/path/to/bee-wippy
```

`CheckRepositoryLayout` validates the lock/configuration boundary;
`CheckEntryDeclarations`, `CheckImportTargetsExist`, `CheckLayerBoundaries`,
`CheckImportCycles`, and `CheckCoreOmitsApplicationIdentities` validate the
registry graph and source containment. `CheckApplicationAdmission`,
`CheckOrdinaryAdmissionPolicies`, `CheckOrdinaryAppSubsystemBoundary`,
`CheckWorkspaceStorageBoundary`, `CheckApprovalStorePolicies`, and
`CheckClientLaunchIdentity` validate admission and policy ownership.

`CheckValueInterfaceClosures`, `CheckDriverContractClosures`,
`CheckPresenterProcessTerminalPurity`, `CheckPureSyncProtocol`,
`CheckSQLiteInventory`, `CheckTerminalHostInventory`, and `CheckNoHTTPService`
cover value-library, driver, process, storage, terminal, and service
constraints. `CheckLoadedInventories` runs `registry list --json` against both
source and `dist/bee.wapp` and requires exact declared identity sets.

This replaces the previous Python checker. The admitted inventory now includes
`bee.governance:db`, and ordinary applications must retain its store denial.
The Makefile gate runs vet and regression tests before inspecting actual source
and pack inventories. YAML mutation tests prove that extra exact-policy fields,
an explicit terminal `command: null`, and scalar launcher resources are refused.
Other resource-containment checks accept either runtime-supported resource
shape; exact policy comparisons preserve their required scalar or list shape.
