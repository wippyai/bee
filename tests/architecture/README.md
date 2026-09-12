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

The Python checker in `tests/architecture.py` remains the parity reference.
The current Go port additionally requires `bee.governance:db` in the SQLite
inventory and denies it to ordinary apps; the Python reference currently has
the older nine-entry inventory and does not assert that denial.
