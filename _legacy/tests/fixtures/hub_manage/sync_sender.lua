local transaction = require("transaction")
local version = require("version")
local types = require("types")
return {send = function(_: string, _: version.Descriptor, _: string, _: types.SendOptions): transaction.Result
    return transaction.failure("UNAVAILABLE", "fixture sender is intentionally unwired")
end}
