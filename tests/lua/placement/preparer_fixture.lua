-- MIT. Host-selected preparer fault fixture.
local registry = require("registry")
local process = require("process")
local M = {}
function M.plan(value: unknown): unknown
    local entry = registry.get("bee.placement.native:preparer_fixture_config")
    if entry and entry.data and entry.data.oversized_state then return {ok = true, value = {state = {owned = string.rep("x", 70000)}}} end
    return {ok = true, value = {state = {owned = true}}}
end
function M.setup(value: unknown): unknown
    local entry = registry.get("bee.placement.native:preparer_fixture_config")
    return {ok = true, value = entry and entry.data or {}}
end
function M.cleanup(value: unknown): unknown
    local entry = registry.get("bee.placement.native:preparer_fixture_config")
    if entry and entry.data and type(entry.data.cleanup_observer) == "string" then
        local release = assert(process.listen("bee.test.preparer.release", {message = true}))
        assert(process.send(entry.data.cleanup_observer, "bee.test.preparer.entered", {}))
        assert((release:receive()))
        process.unlisten(release)
    end
    if entry and entry.data and entry.data.cleanup_failure then return {ok = false, error = {message = "fixture cleanup failure"}} end
    if entry and entry.data and entry.data.cleanup_retained then return {ok = true, value = {retained = true, reason = "fixture retention"}} end
    return {ok = true, value = {retained = false}}
end
return M
