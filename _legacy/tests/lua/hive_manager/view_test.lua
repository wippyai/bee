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
local OWNER_EXECUTION = string.rep("e", 32)
local SAMPLED_AT = "2026-09-09T00:00:00.000Z"
local function presence(node_id: string, role: string, cluster_size: integer): types.Reply
    return types.reply_ok("r", {protocol_revision = types.REVISION, node_id = node_id, role = role,
        cluster_size = cluster_size, sampled_at = SAMPLED_AT})
end
local function stats(heap: integer, goroutines: integer): types.Reply
    return types.reply_ok("r", {memory = {heap_alloc = heap}, goroutines = goroutines,
        cpu_count = 8, sampled_at = SAMPLED_AT})
end
local function populated(source: string): model.State
    local state = model.new({forge = "Forge"})
    model.set_supervisor(state, true, "")
    local members: {directory.Member} = {}
    for index = 1, 12 do
        local id = index == 1 and "forge" or ("node-" .. tostring(index))
        members[#members + 1] = {node_id = id, is_local = index == 1, addr = "10.0.0." .. tostring(index) .. ":7946"}
    end
    model.apply_members(state, members)
    model.apply_presence(state, "forge", presence("forge", "leader", 12))
    model.apply_presence(state, "node-2", types.reply_error("r", types.fault("UNAVAILABLE", "peer \27[2J ended\r")))
    model.apply_stats(state, "forge", stats(3145728, 40))
    model.apply_catalog(state, "forge", {available = true, reason = "", workspaces = {
        {workspace_id = "ws1", label = "main \7bell", served = true},
        {workspace_id = "ws2", label = "second", served = false}}, next_after = nil})
    model.set_pane(state, "workspaces")
    model.move(state, 1)
    local intent = model.attach_intent(state, "observe", "view-key")
    if not intent then error("view test attach intent missing") end
    model.apply_outcome(state, intent, {ok = true, code = "", message = "", session_id = "session-1", mode = "observe",
        viewer = "{local@bee.hive.desktop:display_host|1}", owner_execution = OWNER_EXECUTION})
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
                        test.is_nil((row:find("\27[31m", 1, true)))
                        test.is_nil((row:find("\27[2J", 1, true)))
                        test.is_nil((row:find("\r", 1, true)))
                        test.is_nil((row:find("\7", 1, true)))
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
            local wide = table.concat(view.draw(240, 30, appearance.defaults(), state, 0, "").rows, "\n")
            test.is_true(wide:find("3.0 MiB", 1, true) ~= nil)
            test.is_true(wide:find("owner execution " .. OWNER_EXECUTION, 1, true) ~= nil)
            local kinds: {[string]: boolean} = {}
            for _, hit in ipairs(frame.hits) do kinds[hit.kind] = true end
            test.is_true(kinds["node"] and kinds["workspace"] and kinds["control"] and kinds["observe"] and kinds["refresh"] and kinds["technical"])
            test.is_nil(kinds["open"])
            local found = frames.hit(frame.hits, 3, 4)
            test.eq(found and found.kind, "node")
            test.eq(found and found.key, "forge")
        end)
        test.it("shows whether a host serves each workspace without inferring a free display", function()
            local state = populated("live")
            model.apply_catalog(state, "forge", {available = true, reason = "", next_after = "cursor", workspaces = {
                {workspace_id = "ws1", label = "retained", served = true},
                {workspace_id = "ws2", label = "archive", served = false}}})
            local rows = view.draw(180, 30, appearance.defaults(), state, 0, "").rows
            local text = table.concat(rows, "\n"):gsub("\27%[[0-9;]*m", "")
            if not text:find("retained  served", 1, true) or not text:find("archive  not served", 1, true) then
                local shown: {string} = {}
                for _, row in ipairs(rows) do
                    local plain: string = row:gsub("\27%[[0-9;]*m", "")
                    if plain:find("retained", 1, true) or plain:find("archive", 1, true) or plain:find("Page", 1, true) then
                        shown[#shown + 1] = plain
                    end
                end
                error("workspace rows were not rendered: " .. table.concat(shown, "\\n"))
            end
            test.is_true(text:find("retained  served", 1, true) ~= nil)
            test.is_true(text:find("archive  not served", 1, true) ~= nil)
            test.is_true(text:find("Page 1 · more", 1, true) ~= nil)
            test.is_nil((text:find("available to control", 1, true)))
        end)
        test.it("keeps the selected workspace visible when the catalog exceeds the pane", function()
            local state = populated("live")
            local workspaces: {directory.Workspace} = {}
            for index = 1, 20 do
                workspaces[index] = {workspace_id = "ws-" .. tostring(index), label = "Workspace " .. tostring(index), served = false}
            end
            model.apply_catalog(state, "forge", {available = true, reason = "", workspaces = workspaces, next_after = nil})
            model.set_pane(state, "workspaces")
            model.move(state, 20)
            for _, height in ipairs({14, 30}) do
                local frame = view.draw(100, height, appearance.defaults(), state, 0, "")
                local found = false
                for _, hit in ipairs(frame.hits) do
                    if hit.kind == "workspace" and hit.key == "ws-20" then found = true end
                end
                test.is_true(found)
            end
            model.move(state, -19)
            local first = false
            for _, hit in ipairs(view.draw(100, 30, appearance.defaults(), state, 0, "").hits) do
                if hit.kind == "workspace" and hit.key == "ws-1" then first = true end
            end
            test.is_true(first)
        end)
        test.it("separates membership from service readiness and keeps Raft roles in details", function()
            local state = model.new({})
            model.set_supervisor(state, true, "")
            model.apply_members(state, {{node_id = "local", is_local = true, addr = ""},
                {node_id = "display", is_local = false, addr = ""}})
            model.apply_presence(state, "local", presence("local", "non-member", 2))
            model.apply_presence(state, "display", types.reply_error("r", types.fault("UNAVAILABLE", "destination node is not configured")))
            local drawn = view.draw(180, 30, appearance.defaults(), state, 0, "").rows
            local text = table.concat(drawn, "\n")
            test.is_true(text:find("COMPUTER", 1, true) ~= nil)
            test.is_true(text:find("STATE", 1, true) ~= nil)
            test.is_nil((text:find("MEMBERSHIP", 1, true)))
            test.is_nil((text:find("BEE SERVICE", 1, true)))
            test.eq(cell(drawn, "local · this computer", "STATE", 10), "online")
            test.eq(cell(drawn, "display ", "STATE", 10), "offline")
            test.is_nil((text:find("non-member", 1, true)))
            model.toggle_technical(state)
            local tech_drawn = view.draw(180, 30, appearance.defaults(), state, 0, "").rows
            text = table.concat(tech_drawn, "\n")
            test.is_true(text:find("MEMBERSHIP", 1, true) ~= nil)
            test.is_true(text:find("BEE SERVICE", 1, true) ~= nil)
            test.eq(cell(tech_drawn, "local · this node", "MEMBERSHIP", 10), "present")
            test.eq(cell(tech_drawn, "display ", "MEMBERSHIP", 10), "present")
            test.is_true(text:find("Raft role non-member", 1, true) ~= nil)
            model.apply_members(state, {{node_id = "local", is_local = true, addr = ""}})
            test.eq(cell(view.draw(180, 30, appearance.defaults(), state, 0, "").rows, "display ", "MEMBERSHIP", 10), "left")
        end)
        test.it("puts the workspaces right under a short node list and names an empty hive's next action", function()
            local state = model.new({})
            model.set_supervisor(state, true, "")
            model.apply_members(state, {{node_id = "local", is_local = true, addr = ""}})
            local rows: {string} = {}
            for index, row in ipairs(view.draw(160, 48, appearance.defaults(), state, 0, "").rows) do rows[index] = row:gsub("\27%[[0-9;]*m", "") end
            test.is_true(rows[4]:find("local · this computer", 1, true) ~= nil)
            test.eq(rows[5], string.rep("─", 160))
            test.is_true(rows[6]:find("local", 1, true) ~= nil)
            test.is_true(rows[7]:find("Open the computer to list its workspaces", 1, true) ~= nil)
            local empty = model.new({})
            model.set_supervisor(empty, true, "")
            local lonely = table.concat(view.draw(100, 20, appearance.defaults(), empty, 0, "").rows, "\n")
            test.is_true(lonely:find("No computers connected", 1, true) ~= nil)
            test.is_true(lonely:find("Computers appear here when they join your hive · R refresh", 1, true) ~= nil)
            local footer = view.draw(80, 24, appearance.defaults(), state, 0, "").rows[24]:gsub("\27%[[0-9;]*m", "")
            test.is_true(footer:find("Enter open", 1, true) ~= nil)
            test.is_true(footer:find("? help", 1, true) ~= nil)
            test.eq(tty.text.width(footer), 80)
        end)
        test.it("shows a unavailable supervisor and an absent membership without inventing nodes", function()
            local state = model.new({})
            model.set_supervisor(state, false, "supervisor is not running")
            model.apply_members(state, {{node_id = "local", is_local = true, addr = ""}}, "membership unavailable")
            model.apply_presence(state, "local", types.reply_error("r", types.fault("UNAVAILABLE", "no supervisor to ask")))
            model.apply_catalog(state, "local", {available = false, reason = "No supervisor is available", workspaces = {}, next_after = nil})
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
        test.it("renders default named computers view and details view at 120x36 and 80x24", function()
            local uuid_node = "bcc35ad9-330b-5d50-846a-a24873771ac6"
            local display_id = "17d52a44-0000-0000-0000-00000017d52a"
            local state = model.new({})
            model.set_supervisor(state, true, "")
            model.apply_members(state, {
                {node_id = uuid_node, is_local = true, addr = "192.168.1.10:7946"},
                {node_id = display_id, is_local = false, addr = "192.168.1.20:7946", client_only = true},
            })
            model.apply_presence(state, uuid_node, presence(uuid_node, "leader", 2))
            model.apply_stats(state, uuid_node, stats(2097152, 24))
            model.apply_catalog(state, uuid_node, {available = true, reason = "", workspaces = {
                {workspace_id = "ws-work", label = "primary work", served = true},
            }, next_after = nil})

            -- 1. Default View at 120x36
            local f120 = view.draw(120, 36, appearance.defaults(), state, 0, "")
            test.eq(#f120.rows, 36)
            for _, row in ipairs(f120.rows) do test.eq(tty.text.width(row), 120) end
            local text120 = table.concat(f120.rows, "\n"):gsub("\27%[[0-9;]*m", "")
            if not text120:find("HIVE MANAGER", 1, true) then error("missing HIVE MANAGER in text120:\n" .. text120) end
            if not text120:find("COMPUTER", 1, true) then error("missing COMPUTER in text120:\n" .. text120) end
            if not text120:find("STATE", 1, true) then error("missing STATE in text120:\n" .. text120) end
            if text120:find("MEMBERSHIP", 1, true) then error("MEMBERSHIP should not be in text120") end
            if text120:find("BEE SERVICE", 1, true) then error("BEE SERVICE should not be in text120") end
            if text120:find("bcc35ad9-330b-5d50-846a-a24873771ac6", 1, true) then error("UUID should not be in text120") end
            if text120:find("Raft role", 1, true) then error("Raft role should not be in text120") end
            if not text120:find("online", 1, true) then error("missing online in text120:\n" .. text120) end
            if not text120:find("◫ Display ·", 1, true) then error("missing ◫ Display · in text120:\n" .. text120) end
            if not text120:find("display", 1, true) then error("missing display in text120:\n" .. text120) end
            if not text120:find("primary work  served", 1, true) then error("missing primary work  served in text120:\n" .. text120) end

            -- 2. Default View at 80x24
            local f80 = view.draw(80, 24, appearance.defaults(), state, 0, "")
            test.eq(#f80.rows, 24)
            for _, row in ipairs(f80.rows) do test.eq(tty.text.width(row), 80) end
            local text80 = table.concat(f80.rows, "\n"):gsub("\27%[[0-9;]*m", "")
            if not text80:find("HIVE MANAGER", 1, true) then error("missing HIVE MANAGER in text80") end
            if not text80:find("COMPUTER", 1, true) then error("missing COMPUTER in text80") end
            if not text80:find("online", 1, true) then error("missing online in text80") end
            if not text80:find("◫ Display ·", 1, true) then error("missing ◫ Display · in text80:\n" .. text80) end
            if text80:find("bcc35ad9-330b-5d50-846a-a24873771ac6", 1, true) then error("UUID should not be in text80") end

            -- 3. Details View at 120x36
            model.toggle_technical(state)
            local tech120 = view.draw(120, 36, appearance.defaults(), state, 0, "")
            test.eq(#tech120.rows, 36)
            for _, row in ipairs(tech120.rows) do test.eq(tty.text.width(row), 120) end
            local tech_text120 = table.concat(tech120.rows, "\n"):gsub("\27%[[0-9;]*m", "")
            if not tech_text120:find("MEMBERSHIP", 1, true) then error("missing MEMBERSHIP in tech120") end
            if not tech_text120:find("BEE SERVICE", 1, true) then error("missing BEE SERVICE in tech120") end
            if not tech_text120:find(uuid_node, 1, true) then error("missing UUID in tech120") end
            if not tech_text120:find("Raft role leader", 1, true) then error("missing Raft role leader in tech120:\n" .. tech_text120) end
            if not tech_text120:find("present", 1, true) then error("missing present in tech120") end
            if not tech_text120:find("ready", 1, true) then error("missing ready in tech120") end

            -- 4. Details View at 80x24
            local tech80 = view.draw(80, 24, appearance.defaults(), state, 0, "")
            test.eq(#tech80.rows, 24)
            for _, row in ipairs(tech80.rows) do test.eq(tty.text.width(row), 80) end
            local tech_text80 = table.concat(tech80.rows, "\n"):gsub("\27%[[0-9;]*m", "")
            if not tech_text80:find("MEMBERSHIP", 1, true) then error("missing MEMBERSHIP in tech80") end
            if not tech_text80:find("BEE SERVICE", 1, true) then error("missing BEE SERVICE in tech80") end
            if not tech_text80:find("Raft role", 1, true) then error("missing Raft role in tech80") end
        end)
    end)
end
return require("test").run_cases(define_tests)
