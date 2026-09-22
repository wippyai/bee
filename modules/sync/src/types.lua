-- MIT. Shared Sync obligations. A host selects the concrete replica sender.
local transaction = require("transaction")
local version = require("version")
local M = {}

type SendOptions = {timeout: string?, source_cursor: integer}
type Sender = {
    send: fun(destination: string, descriptor: version.Descriptor, content: string, options: SendOptions): transaction.Result,
}

return M
