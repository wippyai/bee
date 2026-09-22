-- MIT. Fixture-only host selection for the Sync distributor, which this
-- authoring acceptance never invokes.
local transaction = require("transaction")
local version = require("version")

return {
    send = function(_: string, _: version.Descriptor, _: string,
        _: {timeout: string?, source_cursor: integer}): transaction.Result
        return transaction.failure("UNAVAILABLE", "workspace fixture sender is not used")
    end,
}
