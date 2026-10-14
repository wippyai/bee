-- MIT. Verified Hub artifacts and captured resident package definitions.
local bounds = require("bounds")
local limits = require("limits")
local catalog = require("catalog")
local inspect = require("inspect")
local inspection = require("inspection")
local requirements = require("requirements")
local inventory = require("inventory")
local M = {}
function M.new(state: unknown, installed: inventory.Result, target: string): {versions: (string, integer) -> ({string}?, boolean?, string?),
    artifact: (string, string) -> (inspection.Inspection?, string?)}
    return {versions = catalog.available,
        artifact = function(component: string, version: string): (inspection.Inspection?, string?)
            if component ~= target then
                for _, item in ipairs(installed.modules) do
                    if item.component == component and item.version == version and item.entries > 0 then
                        local captured = bounds.object(state)
                        if not captured or type(captured.entries) ~= "table" then return nil, "invalid captured registry" end
                        local entries: {inspection.Entry} = {}
                        for _, raw in ipairs(captured.entries) do
                            local entry = bounds.object(raw)
                            local owned = entry and bounds.object(entry.registry)
                            if entry and owned and owned.owner == component then
                                local id, kind = bounds.id(entry.id), bounds.id(entry.kind)
                                if not id or not kind then return nil, "invalid resident package entry" end
                                if #entries >= limits.MAX_PACKAGE_ENTRIES then return nil, "resident package entry count exceeds planning bound" end
                                entries[#entries + 1] = {id = id, kind = kind, meta = bounds.object(entry.meta) or {}, data = entry.data}
                            end
                        end
                        local holes, problem = requirements.read(entries, {})
                        if not holes then return nil, problem end
                        return {component = component, version = version, digest = item.digest, requirements = holes,
                            entries = entries, next_offset = nil, eof = true}, nil
                    end
                end
            end
            return inspect.artifact(component, version)
        end}
end

return M
