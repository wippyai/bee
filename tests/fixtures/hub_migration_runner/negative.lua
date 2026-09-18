local adapter = require("adapter")
local migration_binding = require("migration_binding")

local DB = "probe:negative_db"
local FIRST = "acme.app:10_first"
local SECOND = "acme.app:20_second"

local captured = {
    {id = FIRST, meta = {type = "migration", target_db = DB, timestamp = "2026-09-12T10:00:00Z"}, registry = {owner = "acme/app"}},
    {id = SECOND, meta = {type = "migration", target_db = DB, timestamp = "2026-09-12T11:00:00Z"}, registry = {owner = "acme/app"}},
}

local function allowed()
    local value, problem = migration_binding.allowed(captured)
    return {allowed = value, problem = problem}
end

local function absent()
    local value, problem = migration_binding.source(captured).is_applied(DB, FIRST)
    return {applied = value, problem = problem}
end

local function attempt()
    local value, problem = adapter.execute(migration_binding.source(captured), {
        operation = "up", entry_ids = {FIRST}, components = {"acme/app"},
    })
    return {result = value, problem = problem}
end

return {allowed = allowed, absent = absent, attempt = attempt}
