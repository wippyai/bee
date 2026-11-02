-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local format = require("format")
local M = {}
type Entry = {[string]: unknown}

-- The harness bindings a consumed driver artifact activates: its own
-- contract.binding entries declaring meta.type harness.driver. One decoder
-- serves the declaration measured before approval and the consumed artifact.
function M.bindings(approved: {Entry}): ({string}?, string?)
    local seen: {[string]: boolean} = {}
    local bindings: {string} = {}
    for _, entry in ipairs(approved) do
        local id = bounds.id(entry.id)
        if not id or seen[id] then return nil, "approved driver definitions are ambiguous" end
        seen[id] = true
        local meta = bounds.object(entry.meta)
        if entry.kind == "contract.binding" and meta and meta.type == "harness.driver" then bindings[#bindings + 1] = id end
    end
    table.sort(bindings)
    if #bindings > 64 then return nil, "approved driver bindings exceed their bound" end
    return bindings, nil
end
type Login = {provider: string, format: string, path: string}
function M.logins(approved: {Entry}): ({Login}?, string?)
    local logins: {Login} = {}
    local seen: {[string]: boolean} = {}
    for _, entry in ipairs(approved) do
        local meta = bounds.object(entry.meta)
        if meta and meta.type == "bee.credential_format" then
            local id = bounds.id(entry.id)
            local provider = bounds.id(meta.provider)
            local decoded = format.decode(entry.data)
            local path = decoded and decoded.file and decoded.file.path or nil
            if entry.kind ~= "registry.entry" or not id or not provider or not path or seen[provider] then
                return nil, "approved driver login format is invalid"
            end
            seen[provider] = true
            logins[#logins + 1] = {provider = provider, format = assert(id), path = path}
        end
    end
    table.sort(logins, function(a: Login, b: Login): boolean return a.provider < b.provider end)
    return logins, nil
end
return M
