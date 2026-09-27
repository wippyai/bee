-- MIT. Host-selected preparer fault fixture.
local registry = require("registry")
local M = {}
function M.plan(value: unknown): unknown
    return {ok = true, value = {state = {owned = true}}}
end
function M.setup(value: unknown): unknown
    local entry = registry.get("bee.placement.native:preparer_fixture_config")
    return {ok = true, value = entry and entry.data or {}}
end
function M.cleanup(value: unknown): unknown
    local entry = registry.get("bee.placement.native:preparer_fixture_config")
    if entry and entry.data and entry.data.cleanup_failure then return {ok = false, error = {message = "fixture cleanup failure"}} end
    return {ok = true, value = {retained = false}}
end
return M
