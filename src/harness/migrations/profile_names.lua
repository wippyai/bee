-- MIT. Every saved profile carries a name its person recognizes, distinct
-- among the profiles of its driver in that workspace. A profile that still
-- carries its agent's title, the name Bee gave it when it was created, is
-- named after that agent and where it runs; a repeated name gains a number.
local json = require("json")
local registry = require("registry")
local bounds = require("bounds")
local canonical = require("canonical")
local protocol = require("protocol")
local rewrites = require("rewrites")
type Row = {row_id: integer, owner: string, feed: string, key: string, value: {[string]: unknown}, name: string, driver: string}
local function definition_title(pinned: registry.Snapshot, ref: unknown): string?
    local id = bounds.id(ref)
    local entry = id and pinned:get(id)
    local data = entry and bounds.object(entry.data)
    return data and bounds.line(data.title, protocol.MAX_NAME_BYTES) or nil
end
return require("migration").define(function()
    migration("Name each saved profile distinctly for its driver", function()
        database("sqlite", function()
            up(function(db)
                local pinned = assert(registry.snapshot())
                local groups: {[string]: {Row}} = {}
                local order: {string} = {}
                for _, raw in ipairs(assert(db:query("SELECT rowid AS row_id, owner_id, feed, projection_key, value_json FROM bee_sync_projections WHERE feed LIKE 'harness.profiles:%' AND tombstone = 0 ORDER BY owner_id, feed, projection_key"))) do
                    local value = bounds.object(json.decode(raw.value_json))
                    local name = value and bounds.line(value.name, protocol.MAX_NAME_BYTES)
                    local driver = value and bounds.id(value.driver_binding_ref)
                    if value and value.schema_revision == protocol.SCHEMA and name and driver then
                        local title = definition_title(pinned, value.definition_ref)
                        if title and protocol.same_name(name, title) then
                            local placement = bounds.object(value.placement)
                            name = protocol.default_name(title, placement ~= nil and placement.kind == "docker")
                        end
                        local group = raw.owner_id .. "\n" .. raw.feed .. "\n" .. driver
                        if not groups[group] then groups[group] = {}; order[#order + 1] = group end
                        local rows = groups[group]
                        rows[#rows + 1] = {row_id = raw.row_id, owner = raw.owner_id, feed = raw.feed, key = raw.projection_key, value = value, name = name, driver = driver}
                    end
                end
                local feeds: {[string]: rewrites.Feed} = {}
                for _, group in ipairs(order) do
                    local taken: {string} = {}
                    for _, row in ipairs(groups[group]) do
                        local name = protocol.free_name(row.name, taken)
                        taken[#taken + 1] = name
                        local previous = tostring(row.value.name)
                        if name ~= previous then
                            row.value.name = name
                            assert(db:execute("UPDATE bee_sync_projections SET value_json = ? WHERE rowid = ?", {assert(canonical.encode(row.value)), row.row_id}))
                            assert(db:execute([[UPDATE bee_approval_grants SET scope_json = json_set(scope_json, '$.parameters.configuration.name', ?)
                                WHERE domain = 'profile_choices' AND owner_node = ? AND json_extract(metadata_json, '$.profile_id') = ?
                                AND json_extract(scope_json, '$.parameters.configuration.name') = ?]], {name, row.owner, row.key, previous}))
                            feeds[row.owner .. "\n" .. row.feed] = {owner = row.owner, feed = row.feed}
                        end
                    end
                end
                assert(not rewrites.fence_feeds(db, feeds))
            end)
        end)
    end)
end)
