-- SPDX-License-Identifier: MIT
-- App reads use the existing retained catalog. Permission is an ephemeral
-- host admission of the exact sender, never a native attachment grant.
local process = require("process")
local time = require("time")
local types = require("types")
local owner = require("owner")
local catalog = require("catalog")
local M = {}
M.OPERATION = "bee.desktop:catalog"
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
function M.handles(value: unknown): boolean
    if type(value) ~= "table" or type(value.target) ~= "table" then return false end
    return value.target.operation_ref == M.OPERATION
end
function M.request(state: owner.State, sender: string, value: unknown, now: integer)
    local call = types.decode_call(value)
    if not call then return end
    local request_id = call.request_id
    local function refuse(code: string, message: string)
        process.send(sender, types.TOPIC_REPLY, types.reply_error(request_id, types.fault(code, message)))
    end
    if not owner.catalog_reader(state, sender) then refuse("DENIED", "Host has not admitted this application to read displays"); return end
    if call.owner_ref.node_id ~= state.node then refuse("UNSUPPORTED_CAPABILITY", "Remote display browsing is not admitted yet"); return end
    if call.owner_ref.service_id ~= "bee.desktop" or call.owner_ref.resource_ref ~= nil
        or call.target.operation_ref ~= M.OPERATION or call.target.interface_ref ~= nil or next(call.input) ~= nil then
        refuse("INVALID_ARGUMENT", "Display catalog reads accept only the node and an empty input"); return
    end
    if state.stopped or not time.now():before(state.expires_at) or state.workspace_id == "" then
        refuse("UNAVAILABLE", "Display catalog is not ready"); return
    end
    local remaining = 30000
    if call.deadline then
        local deadline = time.parse(FORMAT, call.deadline)
        if not deadline or deadline:utc():format(FORMAT) ~= call.deadline then refuse("INVALID_ARGUMENT", "Invalid catalog deadline"); return end
        remaining = math.floor(deadline:sub(time.now()):milliseconds())
        if remaining <= 0 then refuse("DEADLINE_EXCEEDED", "Catalog deadline passed"); return end
        if remaining > 30000 then remaining = 30000 end
    end
    catalog.request(state.catalog, state.supervisor, state.workspace_id, sender, call, nil, now + remaining)
end
return M
