-- MIT. The inbox frame fits every terminal size, keeps hits inside it,
-- leads with the proposed effect, and lets no control sequence from a
-- request through.
local test = require("test")
local bounds = require("bounds")
local tty = require("tty")
local model = require("model")
local leases = require("leases")
local view = require("view")
local frames = require("frames")
local appearance = require("appearance")
type Object = {[string]: unknown}
local function reply(raw: Object): model.Reply
    local decoded = model.decode_reply(raw)
    if not decoded then error("invalid approval reply fixture") end
    return decoded
end
local function request(id: string, state: string, prompt: string): Object
    return {approval_id = id, workspace_id = "ws-1", requester_id = "bee.test.requester", request_kind = "permission", policy = "inbox-test",
        proposal = {kind = "attempt", ref = "attempt-" .. id, revision = "r1", action_id = "action-" .. id, payload = {tool_name = "Bash", correlation_id = "c-1"}},
        proposal_digest = string.rep("b", 64), prompt = {text = prompt}, revision = 1, state = state, owner_node = "node-1", owner_incarnation = 2,
        expires_at = "2026-09-09T10:00:00.000Z", created_at = "2026-09-09T09:00:00.000Z"}
end
local function define_tests()
    test.describe("Inbox frame", function()
        test.it("offers only capped windows and one-key re-allow choices on a short prompt", function()
            local state = model.new({"ws-1"})
            local item = request("window", "pending", "Write exactly one file")
            item.window_max_ttl_ms = 1800000
            item.reallow = true
            model.apply_inbox(state, "ws-1", reply({ok = true, value = {changes = {{seq = 1, request = item}}, next_seq = 1, more = false}}))
            model.select(state, "window")
            model.apply_read(state, "window", reply({ok = true, value = item}))
            local drawn = view.draw(120, 24, appearance.defaults(), state, model.rows(state), 0, "", leases.new())
            local text = table.concat(drawn.rows):gsub("\27%[[0-9;]*m", "")
            -- The prompt leads with the question; identities and scope are details.
            test.ok(text:find("Write exactly one file", 1, true) ~= nil)
            test.is_nil((text:find("Subject:", 1, true)))
            test.ok(text:find("Capability: Bash", 1, true) ~= nil)
            test.is_nil((text:find("attempt-window", 1, true)))
            test.ok(text:find("Re-allow 30 min", 1, true) ~= nil)
            state.technical = true
            local technical = table.concat(view.draw(120, 24, appearance.defaults(), state, model.rows(state), 0, "", leases.new()).rows):gsub("\27%[[0-9;]*m", "")
            test.ok(technical:find("bee.test.requester", 1, true) ~= nil)
            state.technical = false
            for _, hit in ipairs(drawn.hits) do test.ok(hit.kind ~= "allow_longer") end
            item.window_max_ttl_ms = 14400000
            model.apply_read(state, "window", reply({ok = true, value = item}))
            drawn = view.draw(120, 24, appearance.defaults(), state, model.rows(state), 0, "", leases.new())
            text = table.concat(drawn.rows)
            test.ok(text:find("Re-allow longer", 1, true) ~= nil)
        end)

        test.it("keeps Leases discoverable and selectable through shared More at both sizes", function()
            for _, size in ipairs({{80, 24}, {120, 36}}) do
                local state, slice = model.new({"ws-1"}), leases.new()
                local menu = frames.menu()
                local drawn = view.draw(size[1], size[2], appearance.defaults(), state, {}, 0, "Open a pending request before deciding", slice)
                frames.render(drawn, menu, appearance.defaults())
                test.is_true(drawn.rows[size[2]]:find("R refresh", 1, true) ~= nil)
                test.is_true(drawn.rows[size[2]]:find("? help", 1, true) ~= nil)
                test.is_true(drawn.rows[size[2] - 1]:find("F10 More", 1, true) ~= nil)
                frames.route(menu, {type = "key", action = "press", key_type = "f10"})
                drawn = view.draw(size[1], size[2], appearance.defaults(), state, {}, 0, "", slice)
                frames.render(drawn, menu, appearance.defaults())
                test.is_true(table.concat(drawn.rows):find("V  Leases", 1, true) ~= nil)
                local event = frames.route(menu, {type = "key", action = "press", key_type = "runes", key = "V"})
                test.eq(event and event.type, "mouse")
                local hit = event and frames.hit(drawn.hits, event.x or 0, event.y or 0)
                test.eq(hit and hit.kind, "leases")
                for _, row in ipairs(drawn.rows) do test.eq(tty.text.width(row), size[1]) end
                frames.route(menu, {type = "key", action = "press", key_type = "runes", key = "?"})
                drawn = view.draw(size[1], size[2], appearance.defaults(), state, {}, 0, "", slice)
                frames.render(drawn, menu, appearance.defaults())
                test.is_true(table.concat(drawn.rows):find("V  Leases", 1, true) ~= nil)
                test.is_nil((table.concat(drawn.rows):find("Approve 0", 1, true)))
            end
        end)
        test.it("asks to install an exact app version with approve or deny only, the question first", function()
            local state = model.new({"ws-1"})
            local item = request("install", "pending", "Install Bee application tally 1.0.0. It adds no permissions.")
            item.proposal = {kind = "operation", ref = leases.ACTIVATION, revision = "r1", payload = {version = "1.0.0"}}
            item.window_max_ttl_ms = 14400000
            model.apply_inbox(state, "ws-1", reply({ok = true, value = {changes = {{seq = 1, request = item}}, next_seq = 1, more = false}}))
            model.select(state, "install")
            model.apply_read(state, "install", reply({ok = true, value = item}))
            local drawn = view.draw(120, 24, appearance.defaults(), state, model.rows(state), 0, "", leases.new())
            local rows: {string} = {}
            for index, row in ipairs(drawn.rows) do rows[index] = row:gsub("\27%[[0-9;]*m", "") end
            test.ok(rows[3]:find("Install Bee application tally 1.0.0", 1, true) ~= nil)
            local text = table.concat(rows)
            test.is_nil((text:find("Duration:", 1, true)))
            test.ok(rows[23]:find("A Approve", 1, true) ~= nil)
            test.ok(rows[23]:find("D Deny", 1, true) ~= nil)
            for _, hit in ipairs(drawn.hits) do test.ok(hit.kind ~= "allow_30" and hit.kind ~= "allow_longer") end
            test.is_nil((rows[24]:find("allow once", 1, true)))
        end)
        test.it("keeps lease and grant decisions out of the primary row", function()
            for _, size in ipairs({{120, 36}, {80, 24}}) do
                local shown = view.draw(size[1], size[2], appearance.defaults(), model.new({"ws-1"}), {}, 0, "", leases.new())
                local row = shown.rows[size[2] - 1]
                test.is_nil((row:find("Approve", 1, true)))
                test.is_nil((row:find("Deny", 1, true)))
                test.is_nil((row:find("Lease", 1, true)))
                test.is_nil((row:find("Grant", 1, true)))
                test.is_true(row:find("More", 1, true) ~= nil)
            end
        end)
        test.it("shows the command and effect after a long session and workspace identity", function()
            local session = "bs:" .. string.rep("n", 36) .. ":" .. string.rep("w", 32) .. ":" .. string.rep("s", 36)
            local prompt = "Session " .. session .. " in workspace " .. string.rep("w", 32)
                .. " asks Bash {\"command\":\"touch inbox-proof.txt\"} (leave the requested marker)"
            local state = model.new({"ws-1"})
            local item = request("permission-command", "pending", prompt)
            model.apply_inbox(state, "ws-1", reply({ok = true, value = {changes = {{seq = 1, request = item}}, next_seq = 1, more = false}}))
            model.select(state, "permission-command")
            model.apply_read(state, "permission-command", reply({ok = true, value = item}))
            for _, width in ipairs({80, 160}) do
                local shown = view.draw(width, 30, appearance.defaults(), state, model.rows(state), 0, "", leases.new())
                local plain = table.concat(shown.rows, "\n"):gsub("\27%[[0-9;]*m", "")
                test.ok(plain:find("inbox-proof.txt", 1, true) ~= nil, plain)
                test.ok(plain:find("requested%s+marker") ~= nil, plain)
            end
        end)
        test.it("keeps rows, detail and hits inside every terminal size and strips hostile text", function()
            local state = model.new({"ws-1"})
            local changes: {Object} = {}
            for index = 1, 12 do
                changes[#changes + 1] = {seq = index, approval_id = "r" .. tostring(index), revision = 1, request = request("r" .. tostring(index), index % 3 == 0 and "expired" or "pending", "touch proof.txt \27[31mred\27[0m\r\7 line")}
            end
            model.apply_inbox(state, "ws-1", reply({ok = true, error = nil, value = {changes = changes, next_seq = 12, more = false}, replayed = false}))
            model.select(state, "r5")
            model.apply_read(state, "r5", reply({ok = true, error = nil, value = request("r5", "pending", "touch proof.txt \27[2J"), replayed = false}))
            model.toggle_technical(state)
            for _, width in ipairs({1, 12, 40, 80, 140}) do
                for _, height in ipairs({1, 3, 8, 14, 30}) do
                    local frame = view.draw(width, height, appearance.defaults(), state, model.rows(state), 0, "", leases.new())
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
                        test.not_nil(frames.hit(frame.hits, hit.x, hit.y))
                    end
                end
            end
            local frame = view.draw(100, 30, appearance.defaults(), state, model.rows(state), 0, "", leases.new())
            local text = table.concat(frame.rows, "\n")
            test.is_true(text:find("Effect: Bash", 1, true) ~= nil)
            test.is_true(text:find("Digest", 1, true) ~= nil)
            test.is_true(text:find("Allow once", 1, true) ~= nil)
            local approve = false
            for _, hit in ipairs(frame.hits) do if hit.kind == "approve" then approve = true end end
            test.is_true(approve)
        end)
        test.it("shows saved workspace names and effect cards at both frame sizes", function()
            for _, size in ipairs({{120, 36}, {80, 24}}) do
                local state = model.new({"ws-1"})
                local item = request("card-1", "pending", "Run the API checks?")
                model.apply_inbox(state, "ws-1", reply({ok = true, value = {changes = {{seq = 1, request = item}}, next_seq = 1, more = false}}))
                local shown = view.draw(size[1], size[2], appearance.defaults(), state, model.rows(state), 0, "Decision needed", leases.new(),
                    {["ws-1"] = {label = "Bee", folder = "bee-uisessions"}})
                test.eq(#shown.rows, size[2])
                for _, row in ipairs(shown.rows) do test.eq(tty.text.width(row), size[1]) end
                local plain = table.concat(shown.rows, "\n"):gsub("\27%[[0-9;]*m", "")
                test.is_true(plain:find("NEEDS YOU", 1, true) ~= nil)
                test.is_true(plain:find("Bee / bee-uisessions", 1, true) ~= nil)
                test.is_nil((plain:find("attempt-card-1", 1, true)))
                test.is_true(shown.rows[size[2]]:find("Enter open", 1, true) ~= nil)
            end
        end)
        test.it("shows catalog capability and delta on the ordinary approval screen", function()
            local state = model.new({"ws-1"})
            local item = request("grant-1", "pending", "Install Tally?")
            local proposal = assert(bounds.object(item.proposal))
            proposal.payload = {permission_changes = {"added: Read owned threads"},
                resolved_capabilities = {"Read owned threads"}}
            model.apply_inbox(state, "ws-1", reply({ok = true, error = nil, value = {
                changes = {{seq = 1, approval_id = "grant-1", revision = 1, request = item}},
                next_seq = 1, more = false}, replayed = false}))
            model.select(state, "grant-1")
            model.apply_read(state, "grant-1", reply({ok = true, error = nil, value = item, replayed = false}))
            local frame = view.draw(100, 24, appearance.defaults(), state, model.rows(state), 0, "", leases.new())
            local visible = table.concat(frame.rows, "\n")
            test.is_true(visible:find("Change: added: Read owned threads", 1, true) ~= nil)
            test.is_true(visible:find("Capability: Read owned threads", 1, true) ~= nil)
        end)
        test.it("asks an install question once, with each fact on its own line and the tools agents see", function()
            local state = model.new({"ws-1"})
            local item = request("install-1", "pending", "Install Notes 1.0.0 (made by Claude Code · this bee)? It adds: ...")
            item.proposal = {kind = "operation", ref = "bee.gov:establish-overlay", revision = string.rep("a", 64),
                input_digest = string.rep("a", 64), payload = {title = "Notes", version = "1.0.0",
                    maker = "made by Claude Code · this bee", source_workspace = "notes",
                    permission_changes = {"added: Use an isolated application database named notes"},
                    resolved_capabilities = {"Use an isolated application database named notes",
                        "Let agents you enable call notes_add, notes_list as this application, with this application's grants"},
                    migrations = {{id = "app.notes:create_notes", target_db = "notes"}}}}
            model.apply_inbox(state, "ws-1", reply({ok = true, error = nil, value = {
                changes = {{seq = 1, approval_id = "install-1", revision = 1, request = item}}, next_seq = 1, more = false}, replayed = false}))
            model.select(state, "install-1")
            model.apply_read(state, "install-1", reply({ok = true, error = nil, value = item, replayed = false}))
            local drawn = view.draw(120, 36, appearance.defaults(), state, model.rows(state), 0, "", leases.new())
            local rows: {string} = {}
            for index, row in ipairs(drawn.rows) do rows[index] = row:gsub("\27%[[0-9;]*m", "") end
            local text = table.concat(rows, "\n")
            test.is_true(text:find("▣ Install Notes 1.0.0", 1, true) ~= nil)
            test.is_true(text:find("made by Claude Code · this bee", 1, true) ~= nil)
            test.is_true(text:find("It can", 1, true) ~= nil)
            test.is_true(text:find("◆ Use an isolated application database named notes", 1, true) ~= nil)
            test.is_true(text:find("call notes_add, notes_list", 1, true) ~= nil)
            test.is_true(text:find("It changes your data", 1, true) ~= nil)
            test.is_true(text:find("◆ changes the \"notes\" database (create_notes) — this stays after removal", 1, true) ~= nil)
            test.is_true(text:find("For this version in this workspace.", 1, true) ~= nil)
            -- Each fact once: no paragraph, no change list, no repeated capability.
            test.is_nil((text:find("It adds:", 1, true)))
            test.is_nil((text:find("Change:", 1, true)))
            test.is_nil((text:find("added:", 1, true)))
            local first = text:find("Use an isolated application database named notes", 1, true)
            test.is_nil((text:find("Use an isolated application database named notes", (first or 0) + 1, true)))
            test.is_nil((text:find("app.notes:", 1, true)))
            local approve, deny = false, false
            for _, hit in ipairs(drawn.hits) do
                if hit.kind == "approve" then approve = true end
                if hit.kind == "deny" then deny = true end
            end
            test.is_true(approve and deny)
            test.is_true(rows[36]:find("T technical", 1, true) ~= nil)
            for _, row in ipairs(drawn.rows) do test.eq(tty.text.width(row), 120) end
        end)
        test.it("names what an upgrade adds under Now also and keeps the technical lines behind T", function()
            local state = model.new({"ws-1"})
            local item = request("upgrade-1", "pending", "Install Notes 1.1.0?")
            item.proposal = {kind = "operation", ref = "bee.gov:establish-overlay", revision = string.rep("a", 64),
                input_digest = string.rep("a", 64), payload = {title = "Notes", version = "1.1.0", source_workspace = "notes",
                    grant_predecessor_digest = string.rep("c", 64),
                    permission_changes = {"added: Read owned threads"},
                    resolved_capabilities = {"Use an isolated application database named notes", "Read owned threads"}}}
            model.apply_inbox(state, "ws-1", reply({ok = true, error = nil, value = {
                changes = {{seq = 1, approval_id = "upgrade-1", revision = 1, request = item}}, next_seq = 1, more = false}, replayed = false}))
            model.select(state, "upgrade-1")
            model.apply_read(state, "upgrade-1", reply({ok = true, error = nil, value = item, replayed = false}))
            local text = table.concat(view.draw(120, 36, appearance.defaults(), state, model.rows(state), 0, "", leases.new()).rows, "\n")
            test.is_true(text:find("Now also", 1, true) ~= nil)
            test.is_true(text:find("◆ Read owned threads", 1, true) ~= nil)
            test.is_nil((text:find("added:", 1, true)))
            model.toggle_technical(state)
            local technical = table.concat(view.draw(120, 36, appearance.defaults(), state, model.rows(state), 0, "", leases.new()).rows, "\n")
            test.is_true(technical:find("Capability: Read owned threads", 1, true) ~= nil)
        end)
        test.it("shows a driver install with the driver glyph and a list row without the paragraph", function()
            local state = model.new({"ws-1"})
            local item = request("driver-1", "pending", "Install agent driver stub 1.0.0? It adds no permissions. Applies to this exact version.")
            item.proposal = {kind = "operation", ref = "bee.gov:establish-overlay", revision = string.rep("a", 64),
                input_digest = string.rep("a", 64), payload = {title = "Stub", version = "1.0.0", subject = "driver",
                    source_workspace = "stub", resolved_capabilities = {}, permission_changes = {}}}
            model.apply_inbox(state, "ws-1", reply({ok = true, error = nil, value = {
                changes = {{seq = 1, approval_id = "driver-1", revision = 1, request = item}}, next_seq = 1, more = false}, replayed = false}))
            local listed = table.concat(view.draw(120, 36, appearance.defaults(), state, model.rows(state), 0, "", leases.new()).rows, "\n")
            test.is_true(listed:find("◷ pending", 1, true) ~= nil)
            test.is_true(listed:find("Install driver Stub 1.0.0", 1, true) ~= nil)
            test.is_nil((listed:find("Applies to this exact version", 1, true)))
            model.select(state, "driver-1")
            model.apply_read(state, "driver-1", reply({ok = true, error = nil, value = item, replayed = false}))
            local text = table.concat(view.draw(120, 36, appearance.defaults(), state, model.rows(state), 0, "", leases.new()).rows, "\n")
            test.is_true(text:find("⌁ Install driver Stub 1.0.0", 1, true) ~= nil)
        end)
        test.it("keeps the full bounded capability review visible at desktop height", function()
            local state = model.new({"ws-1"})
            local item = request("grant-many", "pending", "Install the requested capabilities?")
            local changes: {string} = {}
            local resolved: {string} = {}
            for index = 1, 8 do
                changes[index] = "added: Capability " .. tostring(index)
                resolved[index] = "Capability " .. tostring(index)
            end
            local proposal = assert(bounds.object(item.proposal))
            proposal.payload = {permission_changes = changes, resolved_capabilities = resolved}
            model.apply_inbox(state, "ws-1", reply({ok = true, error = nil, value = {
                changes = {{seq = 1, approval_id = "grant-many", revision = 1, request = item}},
                next_seq = 1, more = false}, replayed = false}))
            model.select(state, "grant-many")
            model.apply_read(state, "grant-many", reply({ok = true, error = nil, value = item, replayed = false}))
            local visible = table.concat(view.draw(100, 30, appearance.defaults(), state,
                model.rows(state), 0, "", leases.new()).rows, "\n")
            test.is_true(visible:find("Change: added: Capability 8", 1, true) ~= nil)
            test.is_true(visible:find("Capability: Capability 8", 1, true) ~= nil)
        end)
        test.it("offers no decision without an opened pending request or while one awaits the owner", function()
            local state = model.new({"ws-1"})
            model.apply_inbox(state, "ws-1", reply({ok = true, error = nil, value = {changes = {{seq = 1, approval_id = "r1", revision = 1, request = request("r1", "pending", "x")}}, next_seq = 1, more = false}, replayed = false}))
            model.select(state, "r1")
            local function offers(kind: string): boolean
                local frame = view.draw(100, 30, appearance.defaults(), state, model.rows(state), 0, "", leases.new())
                for _, hit in ipairs(frame.hits) do if hit.kind == kind then return true end end
                return false
            end
            test.is_false(offers("approve"))
            model.apply_read(state, "r1", reply({ok = true, error = nil, value = request("r1", "pending", "x"), replayed = false}))
            test.is_true(offers("approve"))
            test.not_nil(model.decision_intent(state, "q1", "approved"))
            test.is_false(offers("approve"))
            test.is_false(offers("refresh"))
        end)
        test.it("names the empty inbox's next action and keeps hints beside a status", function()
            local state = model.new({"ws-1"})
            local empty = view.draw(100, 20, appearance.defaults(), state, model.rows(state), 0, "Refreshed", leases.new())
            local rows: {string} = {}
            for index, row in ipairs(empty.rows) do rows[index] = row:gsub("\27%[[0-9;]*m", "") end
            test.is_true(rows[3]:find("No decisions needed", 1, true) ~= nil)
            test.is_true(rows[4]:find("R refresh", 1, true) ~= nil)
            test.is_true(rows[18]:find("Refreshed", 1, true) ~= nil)
            test.is_true(rows[20]:find("R refresh", 1, true) ~= nil)
            local idle = view.draw(80, 20, appearance.defaults(), state, model.rows(state), 0, "", leases.new()).rows[20]:gsub("\27%[[0-9;]*m", "")
            test.is_true(idle:find("R refresh", 1, true) ~= nil)
            test.is_true(idle:find("? help", 1, true) ~= nil)
            test.is_nil((idle:find("…", 1, true)))
        end)
        test.it("marks the selected request without color and counts pending requests in the header", function()
            local state = model.new({"ws-1"})
            model.apply_inbox(state, "ws-1", reply({ok = true, error = nil, value = {changes = {
                {seq = 1, approval_id = "r1", revision = 1, request = request("r1", "pending", "x")},
                {seq = 2, approval_id = "r2", revision = 1, request = request("r2", "pending", "y")}}, next_seq = 2, more = false}, replayed = false}))
            model.select(state, "r2")
            local drawn = view.draw(100, 20, appearance.defaults(), state, model.rows(state), 0, "", leases.new())
            local rows: {string} = {}
            for index, row in ipairs(drawn.rows) do rows[index] = row:gsub("\27%[[0-9;]*m", "") end
            test.is_true(rows[1]:find("2 pending · 2 shown", 1, true) ~= nil)
            test.eq(rows[3]:sub(1, 1), " ")
            test.eq(rows[4]:sub(1, #"›"), "›")
            model.apply_read(state, "r2", reply({ok = true, error = nil, value = request("r2", "pending", "y"), replayed = false}))
            model.toggle_technical(state)
            local detailed = table.concat(view.draw(100, 20, appearance.defaults(), state, model.rows(state), 0, "", leases.new()).rows, "\n")
            test.is_true(detailed:find("F10 More", 1, true) ~= nil)
            local details_button = false
            for _, button in ipairs(assert(view.draw(100, 20, appearance.defaults(), state, model.rows(state), 0, "", leases.new()).controls).overflow) do
                if button.kind == "technical" and button.label == "Hide technical" then details_button = true end
            end
            test.is_true(details_button)
        end)
        test.it("shows keyboard guidance when no operation needs attention", function()
            local state = model.new({"ws-1"})
            local frame = view.draw(100, 20, appearance.defaults(), state, model.rows(state), 0, "", leases.new())
            test.is_true(table.concat(frame.rows, "\n"):find("R refresh", 1, true) ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
