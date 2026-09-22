-- MIT. The isolated Gateway fixture does not distribute Sync data.
local transaction = require("transaction")
local version = require("version")
return {
    send = function(_: string, _: version.Descriptor, _: string, _: {timeout: string?, source_cursor: integer}): transaction.Result
        return transaction.failure("UNAVAILABLE", "gateway fixture has no replica transport")
    end,
}
