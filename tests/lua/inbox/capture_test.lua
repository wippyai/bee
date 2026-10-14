local test = require("test")
local fs = require("fs")
local tty = require("tty")
local model = require("model")
local view = require("view")
local leases = require("leases")
local appearance = require("appearance")
local shell = require("shell")
local desktop = require("desktop")
local function capture(name: string, rows: {string})
    test.eq(#rows, 40)
    for _, row in ipairs(rows) do test.eq(tty.text.width(row), 120) end
    assert(assert(fs.get("bee.approvals.inbox:captures")):writefile(name .. "-120x40.txt", tty.text.plain(table.concat(rows, "\n")) .. "\n"))
end
local function define_tests()
    test.describe("Needs you screen captures", function()
        test.it("captures the list, card, empty state and arrival notice through their renderers", function()
            local state = model.new({"workspace"})
            capture("empty", view.draw(120, 40, appearance.defaults(), state, {}, 0, "", leases.new()).rows)
            local item = assert(model.decode_view({approval_id = "request", workspace_id = "workspace", requester_id = "bs:node:workspace:session",
                requesting_session = "bs:node:workspace:session", request_kind = "permission", policy = "agent-access", owner_node = "node", owner_incarnation = 1,
                proposal = {kind = "operation", ref = "bee.gateway:access", revision = "1", payload = {requester_name = "Clock helper", duration = "For this agent session", access_summary = "Find and install apps", consequence = "Installed apps can change this workspace."}},
                proposal_digest = string.rep("a", 64), prompt = {text = "Let this agent session use Hub and Library? It asks: Find and install a clock for my desktop."},
                revision = 1, state = "pending", created_at = "2026-10-13T01:18:41.184Z", expires_at = "2026-10-14T01:18:41.184Z"}))
            model.apply_read(state, "request", {kind = "success", value = item})
            model.select(state, "request")
            capture("list", view.draw(120, 40, appearance.defaults(), state, model.rows(state), 0, "", leases.new()).rows)
            model.apply_read(state, "request", {kind = "success", value = item})
            capture("card", view.draw(120, 40, appearance.defaults(), state, model.rows(state), 0, "", leases.new()).rows)
            local scene = desktop.add(desktop.new(120, 40), "agent", "agent", "Clock helper")
            scene = desktop.add(scene, "inbox", "inbox", "Needs you", nil, nil, false)
            scene = desktop.attend(scene, "inbox")
            capture("new-request-notice", shell.draw(scene, {"agent", "inbox"}, {}, nil, nil, "", "My workspace", appearance.defaults(),
                {alert = {id = "inbox", count = 1, title = "Let Clock helper use Hub and Library?", approval_id = "request"}}).rows)
        end)
    end)
end
return test.run_cases(define_tests)
