-- MIT. Capabilities for the gateway authority.
local time = require("time")
local bounds = require("bounds")
local configuration = require("configuration")
local surface = require("surface")
local access = require("access")
local elevation = require("elevation")
local capability_use = require("capability_use")
local installation = require("installation")
local part_model = require("part_model")
local part_records = require("part_records")
local part_surfaces = require("part_surfaces")
local part_values = require("part_values")
local M = {}
type Reply = part_model.Reply
type Binding = part_model.Binding
local FORMAT = part_values.FORMAT
local fail = part_values.fail
local actor = part_values.actor
local open = part_values.open
local binding_by_id = part_records.binding_by_id
-- Capability elevation and installation requests run as the bound subject:
-- the binding row is rechecked on every call, and only the bound subject may
-- act for its own attempt. Elevation takes its approval policy from the
-- binding's own surface access; installation from the host configuration.
local function own_binding(value: unknown): (Binding?, Reply?)
    local object = bounds.object(value)
    if not object then return nil, fail("INVALID", "request must be an object") end
    local binding_id = bounds.id(object.binding_id)
    if not binding_id then return nil, fail("INVALID", "binding_id is not an identifier") end
    local caller = actor()
    if not caller then return nil, fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return nil, open_failure end
    local binding, missing = binding_by_id(db, binding_id)
    db:release()
    if not binding then return nil, missing end
    if binding.subject ~= caller then return nil, fail("DENIED", "only the bound subject acts for its own attempt") end
    if binding.revoked then return nil, fail("DENIED", "binding is revoked") end
    local expires = time.parse(FORMAT, binding.expires_at)
    if not expires or not time.now():before(expires) then return nil, fail("DENIED", "binding has expired") end
    return binding, nil
end
local function elevation_policy(binding: Binding): (string?, Reply?)
    local current, failure = part_surfaces.surface(binding)
    if not current then return nil, failure or fail("STORAGE", "read surface") end
    local access = current.configuration.access
    if not access then return nil, fail("DENIED", "this agent has no elevation approval policy") end
    return access.policy, nil
end
function M.request_capability(value: unknown): Reply
    local binding, refusal = own_binding(value)
    if not binding then return refusal or fail("UNAVAILABLE", "binding is unavailable") end
    local policy_name, policy_refusal = elevation_policy(binding)
    if not policy_name then return assert(policy_refusal) end
    local object = bounds.object(value) or {}
    return elevation.request(binding, policy_name, {capability = object.capability, parameters = object.parameters, ttl_ms = object.ttl_ms})
end
function M.capability_status(value: unknown): Reply
    local binding, refusal = own_binding(value)
    if not binding then return refusal or fail("UNAVAILABLE", "binding is unavailable") end
    local policy_name, policy_refusal = elevation_policy(binding)
    if not policy_name then return assert(policy_refusal) end
    local object = bounds.object(value) or {}
    return elevation.status(binding, policy_name, object.approval_id)
end
-- A tool exercises only the approved capability this attempt holds; the
-- held approval is checked again on every call.
local function held(value: unknown, tool: string): (Binding?, elevation.Held?, Reply?)
    local binding, refusal = own_binding(value)
    if not binding then return nil, nil, refusal or fail("UNAVAILABLE", "binding is unavailable") end
    local policy_name, policy_refusal = elevation_policy(binding)
    if not policy_name then return nil, nil, policy_refusal end
    local object = bounds.object(value) or {}
    local request, held_refusal = elevation.held(binding, policy_name, object.approval_id, tool)
    if not request then return nil, nil, held_refusal end
    return binding, request, nil
end
function M.process_run(value: unknown): Reply
    local binding, request, refusal = held(value, "process_run")
    if not binding or not request then return refusal or fail("DENIED", "no held capability runs a process") end
    return capability_use.process(binding, request, value)
end
function M.http_request(value: unknown): Reply
    local binding, request, refusal = held(value, "http_request")
    if not binding or not request then return refusal or fail("DENIED", "no held capability sends HTTP requests") end
    return capability_use.http(request, value)
end
local function installation_call(value: unknown, fields: {string}): (Binding?, string?, unknown?, Reply?)
    local binding, refusal = own_binding(value)
    if not binding then return nil, nil, nil, refusal end
    local policy_name, policy_refusal = installation.approval_policy()
    if not policy_name then return nil, nil, nil, policy_refusal end
    local object = bounds.object(value) or {}
    local request: {[string]: unknown} = {}
    for _, name in ipairs(fields) do request[name] = object[name] end
    return binding, policy_name, request, nil
end
function M.install_request(value: unknown): Reply
    local binding, policy_name, request, refusal = installation_call(value, {"component", "version", "parameters"})
    if not binding or not policy_name then return assert(refusal) end
    return installation.request(installation.port(binding), binding, policy_name, "install", request)
end
function M.uninstall_request(value: unknown): Reply
    local binding, policy_name, request, refusal = installation_call(value, {"component"})
    if not binding or not policy_name then return assert(refusal) end
    return installation.request(installation.port(binding), binding, policy_name, "uninstall", request)
end
function M.install_status(value: unknown): Reply
    local binding, policy_name, request, refusal = installation_call(value, {"request_id"})
    if not binding or not policy_name then return assert(refusal) end
    return installation.status(installation.port(binding), binding, policy_name, request)
end
-- The bound-subject door for the sibling publication tool surface: those
-- tools live in their own module (this one is at the checker's inference
-- budget) and resolve their caller through this shared door.
function M.own_binding(value: unknown): (Binding?, Reply?)
    return own_binding(value)
end
return M
