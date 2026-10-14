-- MIT
local test = require("test")
local registry = require("registry")
local process = require("process")
local system = require("system")
local protocol = require("protocol")
local bounds = require("bounds")
local grants = require("grants")

local WORKSPACE = "012345678901234567890123456789ab"
local APP = "remote.discovery:app"
local ADMISSION = "bee.tests.hive:remote_discovery_admission"
local GRANT = "bee.tests.hive:remote_discovery_grant"

local function declare(owner: string)
    local changes = assert(registry.snapshot()):changes()
    changes:create({id = GRANT, kind = "registry.entry", meta = {type = grants.SCHEMA},
        data = {schema_revision = grants.SCHEMA, overlay_owner = owner, workspace_id = WORKSPACE, application = APP}})
    assert(changes:apply())
end

local function withdraw()
    if not registry.get(GRANT) then return end
    local changes = assert(registry.snapshot()):changes()
    changes:delete(GRANT)
    assert(changes:apply())
end

local function define_tests()
    test.describe("Hive remote discovery failures", function()
        test.it("fails discovery when an application admission cannot be read instead of listing no tools", function()
            declare("bee.tests.hive:remote_discovery_owner")
            local changes = assert(registry.snapshot()):changes()
            changes:create({id = ADMISSION, kind = "registry.entry", meta = {type = "bee.node.application_admission"},
                data = {bindings = "unreadable"}})
            assert(changes:apply())
            local reply = assert(protocol.call(assert(system.node.id()), "application.discover", {}, "5s", true))
            changes = assert(registry.snapshot()):changes()
            changes:delete(ADMISSION)
            assert(changes:apply())
            withdraw()
            test.is_false(reply.ok)
            test.contains(tostring(reply.error), "discovery")
        end)
        test.it("fails discovery when the application grants cannot be read", function()
            assert(process.registry.register("bee.test.hive.find_failure"))
            local reply = assert(protocol.call(assert(system.node.id()), "application.discover", {}, "5s", true))
            process.registry.unregister("bee.test.hive.find_failure")
            test.is_false(reply.ok)
            test.contains(tostring(reply.error), "application grants cannot be read")
        end)
        test.it("fails a test plan when the application's overlay cannot be opened", function()
            declare("bee.tests.hive:remote_discovery_owner")
            assert(process.registry.register("bee.test.hive.overlay_failure"))
            local reply = assert(protocol.call(assert(system.node.id()), "application.tests",
                {operation = "list", application = APP}, "5s", true))
            process.registry.unregister("bee.test.hive.overlay_failure")
            withdraw()
            test.is_true(reply.ok, tostring(reply.error))
            local answer = assert(bounds.object(assert(reply.value).reply))
            test.is_false(answer.ok)
            test.contains(tostring(assert(bounds.object(answer.error)).message), "cannot be opened")
        end)
    end)
end

return test.run_cases(define_tests)
