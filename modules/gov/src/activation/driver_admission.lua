-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local drivers = require("drivers")
local M = {}
M.TARGET = "bee.harness.launch:harness_activation"
type Entry = {[string]: unknown}

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
                    local binding_id = config and bounds.id(config.default) or nil
                    local binding = binding_id and entries[binding_id] or nil
                    local meta = binding and bounds.object(binding.meta) or nil
                    local component = type(entry.id) == "string" and entry.id:match("^(bee%.driver%.[a-z][a-z0-9]*)%.") or nil
                    if not component or not drivers.source_of(component) or target.path ~= ".bindings +="
                        or #targets ~= 1 or not binding_id or binding_id:sub(1, #component + 9) ~= component .. ".binding:"
                        or not binding or binding.kind ~= "contract.binding" or not meta or meta.type ~= "harness.driver" then
                        return nil, "approved driver activation append is invalid"
                    end
                    if not seen[binding_id] then additions[#additions + 1], seen[binding_id] = binding_id, true end
                end
            end
        end
    end
    table.sort(additions)
    if #additions > 64 then return nil, "approved driver bindings exceed their bound" end
    return additions, nil
end
return M
