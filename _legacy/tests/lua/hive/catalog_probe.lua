-- MIT. Builds the catalog under the caller's scope and returns a summary.
local catalog = require("catalog")
local function handle(_: unknown): {[string]: unknown}
    local snapshot, err = catalog.snapshot()
    if not snapshot then error(tostring(err)) end
    local operations: {string} = {}
    for ref in pairs(snapshot.operations) do operations[#operations + 1] = ref end
    local interfaces: {string} = {}
    for ref in pairs(snapshot.interfaces) do interfaces[#interfaces + 1] = ref end
    table.sort(operations)
    table.sort(interfaces)
    return {generation = snapshot.generation, operations = operations, interfaces = interfaces, diagnostics = snapshot.diagnostics}
end
return {handle = handle}
