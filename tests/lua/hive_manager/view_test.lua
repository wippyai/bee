-- MIT. The frame fits every terminal size, keeps hits inside it, names a
-- fixture source on every frame, shows the unavailable supervisor state without
-- inventing nodes, and lets no control sequence from an owner through.
local test = require("test")
local tty = require("tty")
local model = require("model")
local view = require("view")
local directory = require("directory")
local types = require("types")
local appearance = require("appearance")
local function populated(source: string): model.State
    local state = model.new(source, "review fixture", {forge = "Forge"})
    model.set_supervisor(state, true, "")
    local members: {directory.Member} = {}
    for index = 1, 12 do
        local id = index == 1 and "forge" or ("node-" .. tostring(index))
        members[#members + 1] = {node_id = id, is_local = index == 1, addr = "10.0.0." .. tostring(index) .. ":7946"}
    end
    model.apply_members(state, members)
    model.apply_presence(state, "forge", types.reply_ok("r", {role = "leader\27[31m", cluster_size = 12, sampled_at = "2026-09-09T00:00:00.000Z"}))
    model.apply_presence(state, "node-2", types.reply_error("r", types.fault("UNAVAILABLE", "peer \27[2J ended\r")))
    model.apply_stats(state, "forge", types.reply_ok("r", {memory = {heap_alloc = 3145728}, goroutines = 40}))
    model.apply_catalog(state, "forge", {available = true, reason = "", owner_generation = "forge-execution-1", desktops = {
        {workspace_id = "ws1", desktop_id = "d1", label = "main \7bell", controller = "", observers = 0},
        {workspace_id = "ws1", desktop_id = "d2", label = "second", controller = "bee.client.laptop", observers = 2}}})
    model.set_pane(state, "desktops")
    model.move(state, 1)
    model.toggle_technical(state)
    return state
end
local function define_tests()
    test.describe("Hive Manager frame", function()
        test.it("keeps rows and hits inside every terminal size and strips hostile text", function()
            local state = populated("live")
            for _, width in ipairs({1, 12, 40, 80, 140}) do
                for _, height in ipairs({1, 3, 8, 14, 30}) do
                    local frame = view.draw(width, height, appearance.defaults(), state, 0, "")
                    test.eq(#frame.rows, height)
                    for _, row in ipairs(frame.rows) do
                        test.eq(tty.text.width(row), width)
                        test.is_nil(row:find("\27[31m", 1, true))
                        test.is_nil(row:find("\27[2J", 1, true))
                        test.is_nil(row:find("\r", 1, true))
                        test.is_nil(row:find("\7", 1, true))
                    end
                    for _, hit in ipairs(frame.hits) do
                        test.is_true(hit.x >= 1 and hit.y >= 1)
                        test.is_true(hit.x + hit.width - 1 <= width)
                        test.is_true(hit.y + hit.height - 1 <= height)
                    end
                end
            end
            local frame = view.draw(120, 30, appearance.defaults(), state, 0, "")
            local text = table.concat(frame.rows, "\n")
            test.is_true(text:find("HIVE MANAGER", 1, true) ~= nil)
            test.is_nil(text:find("FIXTURE DATA", 1, true))
            test.is_true(text:find("this unavailable", 1, true) == nil)
            test.is_true(text:find("this present      Forge (forge)", 1, true) ~= nil)
            test.is_true(text:find("     present      node-2", 1, true) ~= nil)
            test.is_true(text:find("controlled by bee.client.laptop", 1, true) ~= nil)
            test.is_true(text:find("3.0 MiB", 1, true) ~= nil)
            local wide = table.concat(view.draw(180, 30, appearance.defaults(), state, 0, "").rows, "\n")
            test.is_true(wide:find("owner generation forge-execution-1", 1, true) ~= nil)
            local kinds: {[string]: boolean} = {}
            for _, hit in ipairs(frame.hits) do kinds[hit.kind] = true end
            test.is_true(kinds["node"] and kinds["desktop"] and kinds["control"] and kinds["observe"] and kinds["refresh"] and kinds["technical"])
            test.is_nil(kinds["open"])
            local found = view.hit(frame.hits, 3, 4)
            test.eq(found and found.kind, "node")
            test.eq(found and found.key, "forge")
        end)
        test.it("separates membership from service readiness and keeps Raft roles in details", function()
            local state = model.new("live", "", {})
            model.set_supervisor(state, true, "")
            model.apply_members(state, {{node_id = "local", is_local = true, addr = ""},
                {node_id = "display", is_local = false, addr = ""}})
            model.apply_presence(state, "local", types.reply_ok("r", {role = "non-member", cluster_size = 2}))
            model.apply_presence(state, "display", types.reply_error("r", types.fault("UNAVAILABLE", "destination node is not configured")))
            local text = table.concat(view.draw(180, 30, appearance.defaults(), state, 0, "").rows, "\n")
            test.is_true(text:find("MEMBERSHIP", 1, true) ~= nil)
            test.is_true(text:find("BEE SERVICE", 1, true) ~= nil)
            test.is_true(text:find("this present      local", 1, true) ~= nil)
            test.is_true(text:find("     present      display", 1, true) ~= nil)
            test.is_nil(text:find("non-member", 1, true))
            model.toggle_technical(state)
            text = table.concat(view.draw(180, 30, appearance.defaults(), state, 0, "").rows, "\n")
            test.is_true(text:find("Raft role non-member", 1, true) ~= nil)
            model.apply_members(state, {{node_id = "local", is_local = true, addr = ""}})
            text = table.concat(view.draw(180, 30, appearance.defaults(), state, 0, "").rows, "\n")
            test.is_true(text:find("     left         display", 1, true) ~= nil)
        end)
        test.it("names a fixture source on the frame and offers no control over a controlled desktop", function()
            local state = populated("fixture")
            model.move(state, 1)
            local frame = view.draw(120, 30, appearance.defaults(), state, 0, "")
            local text = table.concat(frame.rows, "\n")
            test.is_true(text:find("FIXTURE DATA, not a live Hive: review fixture", 1, true) ~= nil)
            local kinds: {[string]: boolean} = {}
            for _, hit in ipairs(frame.hits) do kinds[hit.kind] = true end
            test.is_true(kinds["observe"])
            test.is_nil(kinds["control"])
        end)
        test.it("shows a unavailable supervisor and an absent membership without inventing nodes", function()
            local state = model.new("live", "", {})
            model.set_supervisor(state, false, "supervisor is not running")
            model.apply_members(state, {{node_id = "local", is_local = true, addr = ""}}, "membership unavailable")
            model.apply_presence(state, "local", types.reply_error("r", types.fault("UNAVAILABLE", "no supervisor to ask")))
            model.apply_catalog(state, "local", {available = false, reason = directory.DESKTOPS_UNAVAILABLE, owner_generation = "", desktops = {}})
            local frame = view.draw(120, 30, appearance.defaults(), state, 0, "")
            local text = table.concat(frame.rows, "\n")
            test.is_true(text:find("Hive supervisor unavailable: supervisor is not running", 1, true) ~= nil)
            test.is_true(text:find("Membership: membership unavailable", 1, true) ~= nil)
            test.is_true(text:find("local", 1, true) ~= nil)
            test.is_true(text:find("Desktops unavailable: Desktop browsing is not available", 1, true) ~= nil)
            local rows = 0
            for _, hit in ipairs(frame.hits) do if hit.kind == "node" then rows = rows + 1 end end
            test.eq(rows, 1)
        end)
    end)
end
return require("test").run_cases(define_tests)
