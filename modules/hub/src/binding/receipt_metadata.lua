-- SPDX-License-Identifier: MIT
local registry = require("registry")
local bounds = require("bounds")
local operations = require("operations")
local transaction = require("transaction")
local security = require("security")
type Object = {[string]: unknown}
type Entry = {id: string, kind: string, data: Object, meta: Object}

local function handle(): transaction.Result
    if not security.can("bee.hub.migrate_receipts", "bee.hub.binding:receipt_metadata") then
        return transaction.failure("DENIED", "Hub receipt metadata migration is not admitted")
    end
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then return transaction.failure("UNAVAILABLE", tostring(snapshot_error)) end
    local entries, find_error = snapshot:find({[".kind"] = "registry.entry"})
    if find_error then return transaction.failure("UNAVAILABLE", tostring(find_error)) end
    local changes, changes_error = snapshot:changes()
    if not changes then return transaction.failure("UNAVAILABLE", tostring(changes_error)) end
    local count = 0
    for _, entry in ipairs(entries) do
        local data = bounds.object(entry.data)
        local digest = entry.id:match("^bee%.hub%.operations:([0-9a-f]+)$")
        -- Migration 1 decodes the historical receipt identity once. Its data,
        -- ownership and measured digest remain unchanged in the new revision.
        if digest then
            if #digest ~= 64 then return transaction.failure("INVALID", "Historical Hub receipt identity is invalid: " .. entry.id) end
            if not data then return transaction.failure("INVALID", entry.id .. ": Hub operation receipt data is not an object") end
            local meta = bounds.object(entry.meta) or {}
            if meta.type ~= "bee.hub_operation" then
                if meta.type ~= nil then return transaction.failure("CONFLICT", "Hub receipt has conflicting metadata: " .. entry.id) end
                local tagged: Object = {}
                for key, value in pairs(meta) do tagged[key] = value end
                tagged["type"] = "bee.hub_operation"
                local updated: Entry = {id = entry.id, kind = entry.kind, data = assert(data), meta = tagged}
                local receipt, receipt_error = operations.record(updated)
                if not receipt then return transaction.failure("INVALID", entry.id .. ": " .. tostring(receipt_error)) end
                if receipt.digest ~= digest then return transaction.failure("INVALID", entry.id .. ": Historical Hub receipt digest does not match its identity") end
                local staged, stage_error = changes:update(updated)
                if not staged then return transaction.failure("UNAVAILABLE", tostring(stage_error)) end
                count = count + 1
            end
        end
    end
    if count == 0 then return transaction.success({migration = 1, tagged = 0}, false) end
    local applied, apply_error = changes:apply()
    if not applied then return transaction.failure("UNAVAILABLE", tostring(apply_error)) end
    return transaction.success({migration = 1, tagged = count}, false)
end
return {handle = handle}
