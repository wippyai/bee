-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local drivers = require("drivers")
local M = {}
M.TARGET = "bee.harness.launch:harness_activation"
type Entry = {[string]: unknown}

-- One decoder for the declaration measured before approval and recovered
-- from the consumed artifact. It never changes the protected host entry.
function M.append(entry: Entry, entries: {[string]: Entry}): (string?, string?)
    local id = bounds.id(entry.id)
    local component = id and id:match("^(bee%.driver%.[a-z][a-z0-9]*)%.binding:") or nil
    local config, meta = bounds.object(entry.data), bounds.object(entry.meta)
    local targets = config and bounds.dense_list(config.targets, 64, "driver requirement targets") or nil
    local target = targets and #targets == 1 and bounds.object(targets[1]) or nil
    local binding_id = config and bounds.id(config.default) or nil
    local binding = binding_id and entries[binding_id] or nil
    local binding_meta = binding and bounds.object(binding.meta) or nil
    if entry.kind ~= "ns.requirement" or not component or not drivers.source_of(component)
        or not meta or meta.value_kind ~= "contract.binding" or meta.capability ~= nil
        or not target or bounds.fields(target, {"entry", "path"})
        or target.entry ~= M.TARGET or target.path ~= ".bindings +="
        or not binding_id or binding_id:sub(1, #component + 9) ~= component .. ".binding:"
        or not binding or binding.kind ~= "contract.binding" or not binding_meta
        or binding_meta.type ~= "harness.driver" then
        return nil, "approved driver activation append is invalid"
    end
    return binding_id, nil
end

function M.bindings(approved: {Entry}): ({string}?, string?)
    local seen: {[string]: boolean} = {}
    local additions: {string} = {}
    local entries: {[string]: Entry} = {}
    for _, entry in ipairs(approved) do
        local id = bounds.id(entry.id)
        if not id or entries[id] then return nil, "approved driver definitions are ambiguous" end
        entries[id] = entry
    end
    for _, entry in ipairs(approved) do
        if entry.kind == "ns.requirement" then
            local config = bounds.object(entry.data)
            local targets = config and bounds.dense_list(config.targets, 64, "driver requirement targets") or nil
            if not targets then return nil, "approved driver requirement targets are malformed" end
            for _, raw_target in ipairs(targets) do
                local target = bounds.object(raw_target)
                if target and target.entry == M.TARGET then
                    local binding_id, problem = M.append(entry, entries)
                    if not binding_id then return nil, problem end
                    if not seen[binding_id] then additions[#additions + 1], seen[binding_id] = binding_id, true end
                end
            end
        end
    end
    table.sort(additions)
    if #additions > 64 then return nil, "approved driver bindings exceed their bound" end
    return additions, nil
end
-- logins derives the login each approved driver declares for itself: one
-- bee.credential_format entry in its own bee.driver.<name>.credentials
-- namespace, for provider <name>, with a file destination. The host projects
-- the person's machine login for that provider only through this approval.
type Login = {provider: string, format: string, path: string}
function M.logins(approved: {Entry}): ({Login}?, string?)
    local logins: {Login} = {}
    local seen: {[string]: boolean} = {}
    for _, entry in ipairs(approved) do
        local meta = bounds.object(entry.meta)
        if meta and meta.type == "bee.credential_format" then
            local id = bounds.id(entry.id)
            local provider = id and id:match("^bee%.driver%.([a-z][a-z0-9]*)%.credentials:[%w_]+$") or nil
            local data = bounds.object(entry.data)
            local file = data and bounds.object(data.file)
            local path = file and bounds.line(file.path, 256) or nil
            if entry.kind ~= "registry.entry" or not provider or meta.provider ~= provider
                or not data or data.schema_revision ~= "bee.credential-format@1" or not path or seen[provider] then
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
