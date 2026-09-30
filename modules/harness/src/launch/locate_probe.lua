-- MIT. Host-authorized entry point for a descriptor-driven readiness probe.
local bounds = require("bounds")
local registry = require("registry")
local locator = require("locator")

type Object = {[string]: unknown}

local function handle(raw: unknown): Object
    local request = bounds.object(raw)
    if not request then return {ok = false, error = "locate request must be an object"} end
    local extra = bounds.fields(request, {"binding_ref", "profile_id"})
    if extra then return {ok = false, error = extra} end
    local binding_ref, profile_id = bounds.id(request.binding_ref), bounds.id(request.profile_id)
    if not binding_ref or not profile_id then return {ok = false, error = "binding_ref and profile_id are required identifiers"} end
    local pinned, pin_error = registry.snapshot()
    if pin_error or not pinned then return {ok = false, error = "driver registry is unavailable"} end
    local result = locator.locate(pinned, binding_ref, profile_id, locator.new_cache())
    return {ok = true, located = result ~= nil, result = result}
end

return {handle = handle}
