-- MIT. Settings edit mode: the pane states that overlay admission stays host
-- controlled and person approved, fits every terminal size, and its
-- confirmations are single-line questions the interaction decoder accepts.
local test = require("test")
local tty = require("tty")
local appearance = require("appearance")
local interaction = require("interaction")
local view = require("view")
local model = require("model")
local forms = require("forms")
local super_edit = require("super_edit")

local function define_tests()
    test.describe("Settings edit mode", function()
        test.it("refuses broad or incomplete edit areas before making a confirmation", function()
            for _, input in ipairs({"*", "* --for 5m", "bee.* --for 5m", "bee. --for 5m", "bee.demo? --for 5m", "bee.demo --for 5m extra"}) do
                local message, problem = view.confirm_message(input)
                test.is_nil(message)
                test.eq(type(problem), "string")
            end
        end)
        test.it("reviews an area and duration through the existing governance request", function()
            local state = model.new()
            local protection = {revision = 1,
                super_edit = {"bee.apps.settings.app:app", "bee.shell:main"}, entries = {"bee.gov:protected_kernel", "bee.approvals.inbox.app:app"}}
            local workspace = string.rep("a", 32)
            local configuration = assert(super_edit.enable({profiles = {}}, workspace, "node", {"bee.apps.settings.app"},
                "2099-01-01T00:00:00.000Z", protection))
            test.is_nil(model.load(state, workspace, {{id = "bee.apps.settings.app:app", title = "Settings"},
                {id = "bee.approvals.inbox.app:app", title = "Needs you"}}, configuration, protection))
            test.eq(#state.areas, 2)
            test.eq(#state.grants, 1)
            test.eq(state.grants[1].area, "Settings")
            model.enable(state)
            local form = assert(state.form)
            forms.select_set(assert(form.fields[1].select), "bee.apps.settings.app")
            forms.select_set(assert(form.fields[2].select), "8h")
            test.eq(model.request(state), "bee.apps.settings.app --for 8h")
            local shown = view.draw(120, 40, appearance.defaults(), {}, "edit_mode", 0, "", nil, nil, nil, state)
            local rendered = table.concat(shown.rows, "\n")
            test.contains(rendered, "Area")
            test.contains(rendered, "Duration")
            test.contains(rendered, "8 hours")
            test.is_nil((rendered:find("--for", 1, true)))
            state.form = nil
            local grants = table.concat(view.draw(120, 40, appearance.defaults(), {}, "edit_mode", 0, "", nil, nil, nil, state).rows, "\n")
            test.contains(grants, "Settings · expires 2099-01-01")
            test.contains(grants, "Disable all")
            test.is_nil(model.load(state, "another-workspace", {}, configuration, protection))
            test.eq(#state.grants, 0)
        end)
        test.it("feeds form area and duration through the exact-area confirmation validator", function()
            for _, values in ipairs({{"bee.*", "1h"}, {"bee.demo?", "8h"}, {"bee.demo", "25h"}, {"bee.demo", "0h"}}) do
                local state = model.new()
                state.areas = {{id = values[1], title = "Area"}}
                model.enable(state)
                local form = assert(state.form)
                local duration = assert(form.fields[2].select)
                duration.options[#duration.options + 1] = {label = values[2], value = values[2]}
                forms.select_set(duration, values[2])
                local input = assert(model.request(state))
                local message, problem = view.confirm_message(input)
                test.is_nil(message)
                test.eq(type(problem), "string")
                test.eq(#state.grants, 0)
            end
        end)
        test.it("offers editing from a useful empty grant state", function()
            local shown = view.draw(120, 40, appearance.defaults(), {}, "edit_mode", 0)
            local rendered = table.concat(shown.rows, "\n")
            test.contains(rendered, "No active edit grants")
            test.contains(rendered, "E Enable")
            test.is_nil((rendered:find("overlay admission", 1, true)))
        end)
        test.it("shows person-confirmed, bounded edit mode controls at every terminal size", function()
            for _, width in ipairs({1, 12, 28, 48, 80}) do
                for _, height in ipairs({1, 3, 6, 12}) do
                    local drawn = view.draw(width, height, appearance.defaults(), {}, "edit_mode", 0)
                    test.eq(#drawn.rows, height)
                    for _, row in ipairs(drawn.rows) do test.eq(tty.text.width(row), width) end
                    for _, hit in ipairs(drawn.hits) do
                        test.is_true(hit.x >= 1 and hit.y >= 1)
                        test.is_true(hit.x + hit.width - 1 <= width)
                        test.is_true(hit.y + hit.height - 1 <= height)
                    end
                end
            end
            local text = table.concat(view.draw(80, 12, appearance.defaults(), {}, "edit_mode", 0).rows, "\n")
            test.is_true(text:find("Editing applies only to this workspace.", 1, true) ~= nil)
            test.is_true(text:find("Temporarily allow changes to selected parts of Bee.", 1, true) ~= nil)
            test.is_true(text:find("your approval", 1, true) ~= nil)
            test.is_true(text:find("up to 24 hours", 1, true) ~= nil)
            test.is_true(text:find("Each activation needs your approval", 1, true) ~= nil)
            test.is_true(text:find("up to 24 hours.", 1, true) ~= nil)
            local tabs = view.draw(80, 12, appearance.defaults(), {}, "theme", 0).hits
            local has_edit_tab = false
            for _, hit in ipairs(tabs) do if hit.kind == "edit_mode" then has_edit_tab = true end end
            test.is_true(has_edit_tab)
        end)
        test.it("states the workspace scope and duration of overlay removal in a decoder-valid confirmation", function()
            local message = assert(view.confirm_message("", true))
            test.is_true(message:find("this workspace", 1, true) ~= nil)
            test.is_true(message:find("takes effect now", 1, true) ~= nil)
            test.is_true(message:find("until you enable edit mode again", 1, true) ~= nil)
            test.is_nil((message:find("%c")))
            test.not_nil(interaction.spec({version = 1, request_id = "r-2", id = "bee.settings:edit",
                instance_id = "settings", kind = "confirm", title = "Disable edit mode",
                message = message, accept = "Disable", initial = ""}))
        end)
        test.it("retains all sixteen reviewed decisions in a broker confirmation target", function()
            local decisions: {{[string]: unknown}} = {}
            for index = 1, 16 do
                decisions[index] = {approval_id = "approval-" .. string.rep("a", 24) .. tostring(index), expected_revision = 1,
                    proposal_digest = string.rep("a", 64), reviewed_digest = string.rep("b", 64), decision = "approved"}
            end
            local decoded = assert(interaction.spec({version = 1, request_id = "batch-1", id = "bee.inbox:batch",
                instance_id = "inbox", kind = "confirm", title = "Approve 16 requests?", message = "Review these requests",
                accept = "Approve all", initial = "", target = {decisions = decisions}}))
            test.eq(assert(decoded.target).decisions, decisions)
            test.is_nil(interaction.spec({version = 1, request_id = "batch-2", id = "bee.inbox:batch", instance_id = "inbox",
                kind = "confirm", title = "Batch", message = "", accept = "Approve", initial = "",
                target = {oversized = string.rep("x", 8192)}}))
        end)
        test.it("builds a decoder-valid single-line edit-mode confirmation", function()
            local message = assert(view.confirm_message("bee.ux_demo --for 1m"))
            test.is_nil((message:find("%c")))
            test.not_nil(interaction.spec({version = 1, request_id = "r-1", id = "bee.settings:edit",
                instance_id = "settings", kind = "confirm", title = "Confirm edit mode",
                message = message, accept = "Enable", initial = ""}))
        end)
    end)
end
return test.run_cases(define_tests)
