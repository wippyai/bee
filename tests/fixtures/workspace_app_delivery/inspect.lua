-- MIT. Read the installed registry and the broker's admitted policy list.
local registry = require("registry")
local env = require("env")
local logger = require("logger")
local time = require("time")
local fs = require("fs")
local json = require("json")
local catalog = require("catalog")
local naming = require("workspace_applications")
local grants = require("capability_grants")
local vocabulary = require("capability_catalog")

local function inspect()
    local workspace = env.get("bee.workspace_app_probe:workspace")
    local identity = assert(naming.identity(workspace, "tally"))
    local installed_entry, installed_error = registry.get(assert(grants.record_id(identity.overlay_owner)))
    if not installed_entry then error("grant record unavailable: " .. tostring(installed_error)) end
    local host_catalog = assert(vocabulary.decode(assert(registry.get("bee:capability_catalog"))))
    local installed = assert(grants.decode(installed_entry, identity.overlay_owner,
        workspace, identity.definition_id, host_catalog))
    assert(grants.live(installed, function(id: string): unknown return registry.get(id) end))
    assert(#(installed.capabilities :: {unknown}) == 1)
    local capability = (installed.capabilities :: {{[string]: unknown}})[1]
    assert(capability.capability == "threads.read")
    local generated_policy = (installed.policies :: {{[string]: unknown}})[1]
    local policy_id = generated_policy.id
    local requirement = assert(registry.get("app.tally:threads_read"))
    assert((requirement.data :: {[string]: unknown}).default == policy_id)
    local admitted: {[string]: unknown}? = nil
    for _, binding in ipairs(catalog.read(workspace).bindings) do
        if binding.definition_id == identity.definition_id then admitted = binding; break end
    end
    assert(admitted)
    local policies = admitted.policies :: {string}
    assert(#policies == 2)
    assert(policies[1] == policy_id)
    assert(policies[2] == "bee.security:ordinary_app_subsystem_boundary")
    local body = (generated_policy.data :: {[string]: unknown}).policy :: {[string]: unknown}
    assert(body.effect == "allow")
    assert((body.actions :: {string})[1] == "funcs.call")
    for _, resource in ipairs(body.resources :: {string}) do assert(resource ~= "*") end
    local evidence = {capability = capability.capability,
        policy_id = policy_id, policies = policies, approval_id = installed.approval_id,
        revision = installed.revision}
    local volume = assert(fs.get("bee.workspace_app_probe:grant_evidence"))
    assert(volume:writefile("/grant.json", assert(json.encode(evidence))))
    logger:info("WORKSPACE_APP_GRANTS", evidence)
end

local function main()
    if env.get("bee.workspace_app_probe:inspect") ~= "1" then return end
    local last_error = "grant record did not arrive"
    for _ = 1, 300 do
        local ok, failure = pcall(inspect)
        if ok then
            return
        end
        last_error = tostring(failure)
        time.sleep("100ms")
    end
    error(last_error)
end

return {main = main}
