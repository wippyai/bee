-- MIT. A launched run holds a host lease on its catalog workspace, so the
-- node host manager serves the workspace while the run lasts and may stop it
-- once the run ends; an identity outside the catalog names no host.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local lease = require("lease")
local leases = require("leases")
type Object = {[string]: unknown}
local PROJECTS = "bee.workspace.catalog:projects_fixture"

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for _, name in ipairs(names) do policies[#policies + 1] = assert(security.policy(name)) end
    return security.new_scope(policies)
end
local manager = funcs.new():with_actor(security.new_actor("bee.test.run_lease_manager")):with_scope(scope({
    "bee.workspace.catalog:call_test_policy", "bee.security.storage:workspace_catalog_read_policy", "bee.security.storage:workspace_catalog_manage_policy"}))
local function admit()
    local entry = registry.get("bee:resource_roots")
    if not entry then error("admitted roots entry") end
    local roots = (entry.data :: Object).roots :: {Object}
    for _, root in ipairs(roots) do if root.root_ref == PROJECTS then return end end
    roots[#roots + 1] = {root_ref = PROJECTS, access = "write"}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    assert(changes:apply())
end
local function create(label: string): string
    admit()
    local reply, err = manager:call("bee.workspace.catalog:create", {label = label, root_ref = PROJECTS, subpath = label, create_directory = true})
    if err or type(reply) ~= "table" or reply.ok ~= true then error("create " .. label .. ": " .. tostring(err)) end
    return tostring(((reply :: Object).value :: Object).workspace_id)
end
local function served(workspace_id: string): boolean
    return process.registry.lookup("bee.workspace.host/" .. workspace_id) ~= nil
end
local function define_tests()
    test.describe("Run workspace lease", function()
        test.it("keeps a catalog workspace's host serving while the run holds its lease", function()
            if not process.registry.lookup(leases.MANAGER) then error("the node host manager is not running") end
            local workspace_id = create("run-lease-" .. uuid.v7():sub(-12))
            test.is_false(served(workspace_id))
            local held, refused = lease.hold(workspace_id)
            if not held then error("hold: " .. tostring(refused)) end
            test.is_true(held.managed)
            test.is_true(served(workspace_id))
            test.eq(held.workspace_id, workspace_id)
            lease.release(held)
            test.is_nil(process.registry.lookup(held.name), "the lease name outlived its release")
        end)
        test.it("holds nothing for an identity outside the catalog", function()
            local held, refused = lease.hold("agent-launch-workspace")
            test.is_nil(held)
            test.is_nil(refused)
            local none, missing = lease.hold(nil)
            test.is_nil(none)
            test.is_nil(missing)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
