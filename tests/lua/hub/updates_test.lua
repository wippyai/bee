-- MIT.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local live = require("live")
local about = require("about")
local appearance = require("appearance")
local library = require("library")
local model = require("model")
local fixture = require("fixture")
local function caller(mode: string): funcs.Executor
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.apps.library:hub_client", "bee.apps.library:hub_operations", "bee.apps.library:self_update", "bee.tests.hub:update_fixture_policy", "bee.hub.security:binary_identity_policy"}) do
        policies[#policies + 1] = assert(security.policy(name))
    end
    return assert(funcs.new():with_context({["bee.test.hub.updates"] = mode})
        :with_scope(security.new_scope(policies)):with_actor(security.new_actor("bee.tests.updates")))
end
local function define_tests()
    test.describe("Hub update selection through About, Library and MCP", function()
        test.it("decodes a complete planning artifact once across entry pages", function()
            local before_open = fixture.count("decode_once:opens")
            local before_decode = fixture.count("decode_once:decodes")
            local before_close = fixture.count("decode_once:closes")
            local count = assert(caller("decode_once"):call("bee.tests.hub:artifact_source_probe"))
            test.eq(count, 65)
            test.eq(fixture.count("decode_once:opens") - before_open, 1)
            test.eq(fixture.count("decode_once:decodes") - before_decode, 1)
            test.eq(fixture.count("decode_once:closes") - before_close, 1)
        end)
        for _, mode in ipairs({"mixed", "blocked", "equal", "pages", "yanked", "native", "packset"}) do
            test.it("selects compatible catalog releases: " .. mode, function()
                local executor = caller(mode)
                local reply = assert(executor:call("bee.hub.binding:call", {operation = "updates"}))
                test.is_true(reply.ok, tostring(reply.message))
                local status = live.decode(reply)
                test.eq(status.state, "ready", status.message)
                local update = assert(status.bee_update)
                local offered = mode == "mixed" or mode == "pages" or mode == "native" or mode == "packset"
                test.eq(update.available_version, offered and "0.2.0-alpha.7" or "0.2.0-alpha.5")
                test.eq(update.update_available, offered)
                test.eq(update.needs_new_binary, mode ~= "equal")
                local shown = table.concat(about.draw(160, 35, appearance.defaults(), {}, "about", 0, nil, status, false).rows, "\n")
                if mode ~= "equal" then
                    test.contains(update.reason, "0.2.0-selfupdate.1 needs a newer Bee binary")
                    test.contains(update.reason, (mode == "native" or mode == "packset") and "native component" or "runtime commit")
                    test.contains(shown, "0.2.0-selfupdate.1 needs a newer Bee binary")
                end
                if offered then test.contains(shown, "Bee 0.2.0-alpha.7 is available") end
                local state = model.new("workspace")
                library.apply_installed(state.hub, {ok = true, replayed = false, value = {modules = {
                    {component = "bee/bee", version = "0.2.0-alpha.5", source = "hub", direct = true, used_by = {}}}, roots = {}}})
                library.apply_updates(state.hub, reply)
                local row = model.rows(state, "installed")[1]
                test.eq(row.status, offered and "Update available" or "Installed")
                if mode ~= "equal" then test.contains(row.note, "0.2.0-selfupdate.1 needs a newer Bee binary") end
                if offered then
                    test.eq(row.update, "0.2.0-alpha.7")
                    local prepared = assert(executor:call("bee.hub.binding:call", {operation = "plan", request = {
                        action = "update", component = "bee/bee", version = assert(row.update), migration_policy = "none"}}))
                    test.is_true(prepared.ok, tostring(prepared.message))
                end
                local opened = fixture.count(mode .. ":opens")
                test.eq(fixture.count(mode .. ":closes"), opened)
                local refreshed = assert(executor:call("bee.hub.binding:call", {operation = "updates"}))
                test.is_true(refreshed.ok, tostring(refreshed.message))
                test.eq(fixture.count(mode .. ":opens"), opened)
            end)
        end
    end)
end
return test.run_cases(define_tests)
