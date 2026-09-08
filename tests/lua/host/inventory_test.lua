-- MIT. Live discovery is descriptive and independent from attachment authority.
local test = require("test")
local inventory = require("inventory")
local contract = require("contract")
local json = require("json")
local workspace = "0123456789abcdef0123456789abcdef"
local function opened(): contract.Reply
    local reply = contract.reply("open", "open")
    reply.workspace_id, reply.id, reply.instance_id = workspace, "view", "instance"
    reply.definition_id, reply.title, reply.icon = "test:app", "Terminal", "T"
    reply.mount, reply.resume_state = "secret-mount", "secret-checkpoint"
    return reply
end
local function define_tests()
    test.describe("Host inventory", function()
        test.it("keeps catalog and live revisions independent and excludes credentials", function()
            local empty = inventory.new(workspace)
            local catalog = assert(inventory.set_catalog(empty, {{definition_id = "test:app", definition_revision = "1", title = "Terminal",
                icon = "T", group = "Tools", role = "terminal", singleton = false, policies = {"secret-policy"}}}))
            local live = assert(inventory.observe(catalog, opened()))
            test.eq(empty.catalog_revision, 0)
            test.eq(catalog.catalog_revision, 1)
            test.eq(catalog.views_revision, 0)
            test.eq(live.views_revision, 1)
            test.eq(live.catalog_revision, 1)
            test.eq(#catalog.views, 0)
            local encoded = assert(json.encode({catalog = inventory.catalog_message(live, "connection"), views = inventory.views_message(live, "connection")}))
            test.is_nil(encoded:find("secret", 1, true))
            local views = assert(inventory.views(inventory.views_message(live, "connection")))
            test.eq(views.items[1].workspace_id, workspace)
            views.items[1].title = "changed by consumer"
            test.eq(live.views[1].title, "Terminal")
            test.is_nil(inventory.observe(live, opened()))
        end)
        test.it("updates titles and removes failed exits without rewriting old snapshots", function()
            local initial = assert(inventory.observe(inventory.new(workspace), opened()))
            local reply = opened()
            reply.op, reply.title = "title", "Working"
            local titled = assert(inventory.observe(initial, reply))
            test.eq(titled.views[1].title, "Working")
            test.eq(initial.views[1].title, "Terminal")
            test.is_nil(inventory.observe(titled, reply))
            reply.op, reply.error_code = "close", "cancelled"
            test.is_nil(inventory.observe(titled, reply))
            reply.op, reply.error_code, reply.instance_id = "closed", "application_failed", "old-instance"
            test.is_nil(inventory.observe(titled, reply))
            reply.instance_id = "instance"
            local removed = assert(inventory.observe(titled, reply))
            test.eq(#removed.views, 0)
            test.eq(removed.views_revision, 3)
            test.eq(#titled.views, 1)
        end)
        test.it("rejects foreign, sparse, duplicate and unsupported snapshots", function()
            local live = inventory.observe(inventory.new(workspace), opened())
            if not live then error("Missing opened inventory") end
            local value = inventory.views_message(live, "connection")
            value.items[2] = value.items[1]
            test.is_nil(inventory.views(value))
            value.items[1] = nil
            test.is_nil(inventory.views(value))
            value.items[1], value.items[2] = value.items[2], nil
            value.workspace_id = "ffffffffffffffffffffffffffffffff"
            test.is_nil(inventory.views(value))
            value.workspace_id = workspace; value.version = 2
            test.is_nil(inventory.views(value))
            value.version = 1; value.connection_id = ""
            test.is_nil(inventory.views(value))
            local reply = opened(); reply.workspace_id = "ffffffffffffffffffffffffffffffff"
            test.is_nil(inventory.observe(live, reply))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
