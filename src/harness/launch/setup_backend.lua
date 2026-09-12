-- MIT. Host-selected roots are associated once, after a selected definition.
local funcs = require("funcs")
local registry = require("registry")
local bounds = require("bounds")
local definition = require("definition")
local SETUP = "bee:harness_setup"
local function fail(message: string): {[string]: unknown} return {ok = false, error = message} end
local function same(value: unknown, root: string, access: string): boolean
    local object = bounds.object(value)
    return object ~= nil and object.root_ref == root and object.subpath == "" and object.allowed_access == access
end
local function ensure(workspace: string, name: string, root: string): (boolean, string?)
    local reply, call_error = funcs.call("bee.resources:associate", {workspace_id = workspace, name = name, root_ref = root, subpath = "", allowed_access = "write", expected_revision = 0})
    local value = bounds.object(reply)
    if call_error or not value then return false, tostring(call_error or "associate") end
    if value.ok == true and same(value.value, root, "write") then return true, nil end
    if value.ok ~= false then return false, "associate reply" end
    local error = bounds.object(value.error)
    if not error or error.code ~= "CONFLICT" then return false, tostring(error and error.message or "associate") end
    local listed, list_error = funcs.call("bee.resources:list", {workspace_id = workspace})
    local listed_value = bounds.object(listed)
    local data = listed_value and bounds.object(listed_value.value)
    local associations = data and data.associations
    if list_error or not listed_value or listed_value.ok ~= true or type(associations) ~= "table" then return false, "read existing association" end
    for _, item in ipairs(associations :: {unknown}) do
        local association = bounds.object(item)
        if association and association.name == name then
            if same(association, root, "write") then return true, nil end
            return false, "existing association " .. name .. " differs from host setup"
        end
    end
    return false, "association conflict was not readable"
end
local function handle(raw: unknown): {[string]: unknown}
    local request = bounds.object(raw)
    if not request then return fail("request must be an object") end
    if bounds.fields(request, {"workspace_id", "definition_ref", "expected_definition_digest"}) then return fail("unknown field") end
    local workspace, ref = bounds.id(request.workspace_id), bounds.id(request.definition_ref)
    if not workspace or not ref then return fail("workspace_id and definition_ref are required") end
    local expected = bounds.text(request.expected_definition_digest, 64)
    if not expected or #expected ~= 64 or not expected:match("^[0-9a-f]+$") then return fail("expected_definition_digest must be a lowercase SHA-256 hex digest") end
    local launch, launch_error = definition.load(ref)
    if not launch then return fail(tostring(launch_error)) end
    if launch.digest ~= expected then return fail("launch definition changed") end
    local names: {string} = {}
    if launch.workdir_policy.kind == "declared_resource" and launch.workdir_policy.resource_ref then names[#names + 1] = launch.workdir_policy.resource_ref end
    if launch.session_resource then names[#names + 1] = launch.session_resource end
    if #names == 0 then return {ok = true, resources = {}} end
    local entry = registry.get(SETUP)
    local data = entry and bounds.object(entry.data)
    local roots = data and bounds.object(data.roots)
    if not roots then return fail("host setup roots unavailable") end
    for _, name in ipairs(names) do
        local root = bounds.id(roots[name])
        if not root then return fail("host setup has no root for " .. name) end
        local ok, setup_error = ensure(workspace, name, root)
        if not ok then return fail(setup_error or "associate") end
    end
    return {ok = true, resources = names}
end
return {handle = handle}
