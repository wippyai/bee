-- MIT. The frame fits every terminal size, keeps hits inside it, names a
-- shows the unavailable supervisor state without
-- inventing nodes, and lets no control sequence from an owner through.
local test = require("test")
local tty = require("tty")
local model = require("model")
local view = require("view")
local frames = require("frames")
local directory = require("directory")
local types = require("types")
local appearance = require("appearance")
local function populated(source: string): model.State
    local state = model.new({forge = "Forge"})
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
        {workspace_id = "ws1", desktop_id = "d1", label = "main \7bell"},
        {workspace_id = "ws1", desktop_id = "d2", label = "second"}}})
    model.set_pane(state, "desktops")
    model.move(state, 1)
    model.toggle_technical(state)
    return state
end
-- The cell under a column caption in the first row containing needle, in
-- display columns: every multibyte character counts as one cell.
local function cell(rows: {string}, needle: string, caption: string, size: integer): string?
    local plain: {string} = {}
    for index, row in ipairs(rows) do
        local stripped: string = row:gsub("\27%[[0-9;]*m", "")
        local narrow: string = stripped:gsub("[\194-\244][\128-\191]*", "?")
        plain[index] = narrow
    end
    local column = 0
    for _, row in ipairs(plain) do
        local found: number? = tonumber(row:find(caption, 1, true))
        if found then column = math.floor(found); break end
    end
    if column == 0 then return nil end
    local target: string = needle:gsub("[\194-\244][\128-\191]*", "?")
    for _, row in ipairs(plain) do
        if row:find(target, 1, true) then
            local value: string = row:sub(column, column + size - 1):gsub("%s+$", "")
            return value
        end
    end
    return nil
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
            test.is_true(text:find("this unavailable", 1, true) == nil)
            test.eq(cell(frame.rows, "Forge (forge) · this node", "MEMBERSHIP", 10), "present")
            test.eq(cell(frame.rows, "Forge (forge) · this node", "BEE SERVICE", 11), "ready")
            test.eq(cell(frame.rows, "node-2 ", "MEMBERSHIP", 10), "present")
            test.eq(cell(frame.rows, "node-2 ", "BEE SERVICE", 11), "unavailable")
            test.is_true(text:find("3.0 MiB", 1, true) ~= nil)
            local wide = table.concat(view.draw(180, 30, appearance.defaults(), state, 0, "").rows, "\n")
            test.is_true(wide:find("owner generation forge-execution-1", 1, true) ~= nil)
            local kinds: {[string]: boolean} = {}
            for _, hit in ipairs(frame.hits) do kinds[hit.kind] = true end
            test.is_true(kinds["node"] and kinds["desktop"] and kinds["control"] and kinds["observe"] and kinds["refresh"] and kinds["technical"])
            test.is_nil(kinds["open"])
            local found = frames.hit(frame.hits, 3, 4)
            test.eq(found and found.kind, "node")
            test.eq(found and found.key, "forge")
        end)
        test.it("shows whether a host serves each workspace without inferring a free display", function()
            local state = populated("live")
            model.apply_catalog(state, "forge", {available = true, reason = "", owner_generation = "forge", next_after = "cursor", desktops = {
                {workspace_id = "ws1", desktop_id = "", label = "retained", served = true},
                {workspace_id = "ws2", desktop_id = "", label = "archive", served = false}}})
            local text = table.concat(view.draw(180, 30, appearance.defaults(), state, 0, "").rows, "\n")
            test.is_true(text:find("retained  served", 1, true) ~= nil)
            test.is_true(text:find("archive  not served", 1, true) ~= nil)
            test.is_true(text:find("Page 1 · more", 1, true) ~= nil)
            test.is_nil(text:find("available to control", 1, true))
        end)
        test.it("keeps the selected display visible when the catalog exceeds the pane", function()
            local state = populated("live")
            local desktops: {directory.Desktop} = {}
            for index = 1, 20 do
                desktops[index] = {workspace_id = "ws1", desktop_id = "display-" .. tostring(index), label = "Display " .. tostring(index)}
            end
            model.apply_catalog(state, "forge", {available = true, reason = "", owner_generation = "forge-execution-1", desktops = desktops})
            model.set_pane(state, "desktops")
            model.move(state, 20)
            for _, height in ipairs({14, 30}) do
                local frame = view.draw(100, height, appearance.defaults(), state, 0, "")
                local found = false
                for _, hit in ipairs(frame.hits) do
                    if hit.kind == "desktop" and hit.key == model.desktop_key("ws1", "display-20") then found = true end
                end
                test.is_true(found)
            end
            model.move(state, -19)
            local first = false
            for _, hit in ipairs(view.draw(100, 30, appearance.defaults(), state, 0, "").hits) do
                if hit.kind == "desktop" and hit.key == model.desktop_key("ws1", "display-1") then first = true end
            end
            test.is_true(first)
        end)
        test.it("separates membership from service readiness and keeps Raft roles in details", function()
            local state = model.new({})
            model.set_supervisor(state, true, "")
            model.apply_members(state, {{node_id = "local", is_local = true, addr = ""},
                {node_id = "display", is_local = false, addr = ""}})
            model.apply_presence(state, "local", types.reply_ok("r", {role = "non-member", cluster_size = 2}))
            model.apply_presence(state, "display", types.reply_error("r", types.fault("UNAVAILABLE", "destination node is not configured")))
            local drawn = view.draw(180, 30, appearance.defaults(), state, 0, "").rows
            local text = table.concat(drawn, "\n")
            test.is_true(text:find("MEMBERSHIP", 1, true) ~= nil)
            test.is_true(text:find("BEE SERVICE", 1, true) ~= nil)
            test.eq(cell(drawn, "local · this node", "MEMBERSHIP", 10), "present")
            test.eq(cell(drawn, "display ", "MEMBERSHIP", 10), "present")
            test.is_nil(text:find("non-member", 1, true))
            model.toggle_technical(state)
            text = table.concat(view.draw(180, 30, appearance.defaults(), state, 0, "").rows, "\n")
            test.is_true(text:find("Raft role non-member", 1, true) ~= nil)
            model.apply_members(state, {{node_id = "local", is_local = true, addr = ""}})
            test.eq(cell(view.draw(180, 30, appearance.defaults(), state, 0, "").rows, "display ", "MEMBERSHIP", 10), "left")
        end)
        test.it("puts the desktops right under a short node list and names an empty hive's next action", function()
            local state = model.new({})
            model.set_supervisor(state, true, "")
            model.apply_members(state, {{node_id = "local", is_local = true, addr = ""}})
            local rows: {string} = {}
            for index, row in ipairs(view.draw(160, 48, appearance.defaults(), state, 0, "").rows) do rows[index] = row:gsub("\27%[[0-9;]*m", "") end
            test.is_true(rows[4]:find("local · this node", 1, true) ~= nil)
            test.eq(rows[5], string.rep("─", 160))
            test.is_true(rows[6]:find("Node local", 1, true) ~= nil)
            test.is_true(rows[7]:find("Open the node to list its workspaces", 1, true) ~= nil)
            local empty = model.new({})
            model.set_supervisor(empty, true, "")
            local lonely = table.concat(view.draw(100, 20, appearance.defaults(), empty, 0, "").rows, "\n")
            test.is_true(lonely:find("No nodes reported", 1, true) ~= nil)
            test.is_true(lonely:find("Nodes appear here when they join this hive · R refresh", 1, true) ~= nil)
            local footer = view.draw(80, 24, appearance.defaults(), state, 0, "").rows[24]:gsub("\27%[[0-9;]*m", "")
            test.is_true(footer:find("O observe · R refresh", 1, true) ~= nil)
            test.is_nil(footer:find("…", 1, true))
        end)
        test.it("shows a unavailable supervisor and an absent membership without inventing nodes", function()
            local state = model.new({})
            model.set_supervisor(state, false, "supervisor is not running")
            model.apply_members(state, {{node_id = "local", is_local = true, addr = ""}}, "membership unavailable")
            model.apply_presence(state, "local", types.reply_error("r", types.fault("UNAVAILABLE", "no supervisor to ask")))
            model.apply_catalog(state, "local", {available = false, reason = "No supervisor is available", owner_generation = "", desktops = {}})
            local frame = view.draw(120, 30, appearance.defaults(), state, 0, "")
            local text = table.concat(frame.rows, "\n")
            test.is_true(text:find("Hive supervisor unavailable: supervisor is not running", 1, true) ~= nil)
            test.is_true(text:find("Membership: membership unavailable", 1, true) ~= nil)
            test.is_true(text:find("local", 1, true) ~= nil)
            test.is_true(text:find("Workspaces unavailable: No supervisor is available", 1, true) ~= nil)
            local rows = 0
            for _, hit in ipairs(frame.hits) do if hit.kind == "node" then rows = rows + 1 end end
            test.eq(rows, 1)
        end)
    end)
end
return require("test").run_cases(define_tests)
