-- MIT. The public application test facade. It decodes the request, takes the
-- caller's workspace and actor from the authenticated context, verifies the
-- caller owns the overlay the application is delivered from (the overlay
-- facade lists the caller's own), and only then enters the node's private
-- test backend scope, which records the run in the node database. The caller
-- holds no database or runner authority of its own.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local tests = require("tests")

local OVERLAYS = "bee.gov.binding:overlay_call"
local BACKEND = "bee.node.binding:tests_backend"
local SCOPE = "bee.node.security:tests_backend"

-- owns reports whether the caller owns overlay.
local function owns(overlay: string): (boolean, tests.Reply?)
    local raw, call_error = funcs.new():call(OVERLAYS, {operation = "list"})
    if call_error then return false, tests.fail("UNAVAILABLE", "overlay listing: " .. tostring(call_error)) end
    local reply = bounds.object(raw)
    local value = reply and reply.ok == true and bounds.object(reply.value) or nil
    local rows = value and type(value.overlays) == "table" and value.overlays :: {unknown} or nil
    if not rows then return false, tests.fail("DENIED", "the caller's overlays cannot be listed") end
    for _, row in ipairs(rows) do
        local listed = bounds.object(row)
        if listed and listed.overlay_id == overlay then return true, nil end
    end
    return false, nil
end

local function handle(raw: unknown): tests.Reply
    local request, invalid = tests.decode(raw)
    if not request then return tests.fail("INVALID", invalid or "invalid request") end
    local actor = security.actor()
    local metadata = actor and bounds.object(actor:meta()) or nil
    local workspace = metadata and bounds.id(metadata.workspace_id) or nil
    if not actor or not workspace then return tests.fail("DENIED", "tests need an authenticated workspace caller") end
    local overlay: string? = nil
    if request.application then
        overlay = tests.overlay_of(request.application)
        local owned, fault = owns(overlay)
        if fault then return fault end
        if not owned then
            return tests.fail("DENIED", "application " .. request.application .. " is not delivered from an overlay you own")
        end
    end
    local scope, scope_error = security.named_scope(SCOPE)
    if not scope then return tests.fail("UNAVAILABLE", "test backend scope: " .. tostring(scope_error)) end
    local executor = funcs.new():with_scope(scope)
    if not executor then return tests.fail("UNAVAILABLE", "test backend executor is unavailable") end
    local result, call_error = executor:call(BACKEND, {operation = request.operation, workspace_id = workspace, actor_id = actor:id(),
        overlay = overlay, filter = request.filter, run_id = request.run_id})
    if call_error then return tests.fail("UNAVAILABLE", "test backend: " .. tostring(call_error)) end
    local answer = bounds.object(result)
    if not answer or type(answer.ok) ~= "boolean" then return tests.fail("UNAVAILABLE", "the test backend answered with an invalid reply") end
    if answer.ok then return tests.succeed(answer.value) end
    local fault = bounds.object(answer.error)
    return tests.fail(fault and bounds.text(fault.code, 64) or "FAILED", fault and bounds.text(fault.message, 4096) or "the test run failed")
end

return {handle = handle}
