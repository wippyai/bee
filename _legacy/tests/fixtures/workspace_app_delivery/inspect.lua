-- MIT. Read the installed registry and the broker's admitted policy list.
local bounds = require("bounds")
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
    local workspace = env.get("bee.workspace.app.probe:workspace")
    local identity = assert(naming.identity(workspace, "tally"))
    local installed_entry, installed_error = registry.get(assert(grants.record_id(identity.overlay_owner)))
    if not installed_entry then error("grant record unavailable: " .. tostring(installed_error)) end
    local host_catalog = assert(vocabulary.decode(assert(registry.get("bee.security.capability:capability_catalog"))))
    local installed = assert(grants.decode(installed_entry, identity.overlay_owner,
        workspace, identity.definition_id, host_catalog))
    assert(grants.live(installed, function(id: string): unknown return registry.get(id) end))
    local capabilities = assert(bounds.array(installed.capabilities))
    assert(#capabilities == 4)
    local seen: {[string]: boolean} = {}
    for _, grant in ipairs(capabilities) do seen[grant.capability] = true end
    assert(seen["threads.read"] and seen["workspace.files.read"] and seen["app.database"] and seen["agents.launch"])
    local generated_policies = assert(bounds.array(installed.policies))
    assert(#generated_policies == 4)
    local policy_ids: {[string]: boolean} = {}
    for _, generated_policy in ipairs(generated_policies) do
        policy_ids[generated_policy.id] = true
        local body = assert(bounds.object((assert(bounds.object(generated_policy.data))).policy))
        assert(body.effect == "allow")
        for _, resource in ipairs(assert(bounds.ids(body.resources))) do assert(resource ~= "*") end
    end
    local volumes = assert(bounds.array((installed.volumes or {})))
    assert(#volumes == 1)
    assert(volumes[1].kind == "fs.directory")
    local volume_config = assert(bounds.object(volumes[1].data))
    assert(volume_config.directory == "shared")
    assert(volume_config.readonly == true)
    local databases = assert(bounds.array((installed.databases or {})))
    assert(#databases == 1)
    assert(databases[1].kind == "db.sql.sqlite")
    local expected: {[string]: string} = {["app.tally:threads_read"] = "threads.read",
        ["app.tally:shared_files"] = "workspace.files.read", ["app.tally:tally_db"] = "app.database",
        ["app.tally:agent_launch"] = "agents.launch"}
    for requirement_id in pairs(expected) do
        local requirement = assert(registry.get(requirement_id))
        local default = (assert(bounds.object(requirement.data))).default
        assert(type(default) == "string" and policy_ids[default])
    end
    local admitted: {[string]: unknown}? = nil
    for _, binding in ipairs(catalog.read(workspace).bindings) do
        if binding.definition_id == identity.definition_id then admitted = binding; break end
    end
    assert(admitted)
    local policies = assert(bounds.ids(admitted.policies))
    assert(#policies == 6)
    local boundary_count = 0
    for _, policy_id in ipairs(policies) do
        if policy_id == "bee.security:ordinary_app_subsystem_boundary" then boundary_count = boundary_count + 1
        else assert(policy_ids[policy_id]) end
    end
    assert(boundary_count == 1)
    local names: {string} = {}
    for name in pairs(seen) do names[#names + 1] = name end
    table.sort(names)
    local evidence = {capabilities = names,
        volume_id = volumes[1].id, database_id = databases[1].id,
        policies = policies, approval_id = installed.approval_id,
        revision = installed.revision}
    local volume = assert(fs.get("bee.workspace.app.probe:grant_evidence"))
    assert(volume:writefile("/grant.json", assert(json.encode(evidence))))
    logger:info("WORKSPACE_APP_GRANTS", evidence)
end

local function main()
    if env.get("bee.workspace.app.probe:inspect") ~= "1" then return end
    local last_error = "grant record did not arrive"
    -- The UI may wait for approval and activation after this service boots.
    for _ = 1, 1800 do
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
