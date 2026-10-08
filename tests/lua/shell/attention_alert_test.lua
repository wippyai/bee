-- SPDX-License-Identifier: MIT
local test = require("test")
local model = require("model")
local render = require("render")
local appearance = require("appearance")
local function define_tests()
    test.describe("Request alerts", function()
        test.it("shows a counted alert and request card while preserving occupied and idle keyboards", function()
            for _, occupied in ipairs({true, false}) do
                local scene = model.add(model.new(160, 45), "agent", "agent", "Worker")
                scene = model.add(scene, "inbox", "inbox", "Needs you", nil, nil, false)
                if not occupied then scene = model.focus(scene, "") end
                scene = model.attend(scene, "inbox")
                test.eq(scene.focus, occupied and "agent" or "inbox")
                local shown = render.draw(scene, {"agent", "inbox"}, {}, nil, nil, "", "Workspace", appearance.defaults(),
                    {alert = {id = "inbox", count = 2, title = "Allow Bash to run tests?", approval_id = "request-2"}})
                test.contains(shown.rows[1], "! 2 Needs you")
                test.contains(table.concat(shown.rows, "\n"), "Allow Bash to run tests?")
                test.contains(table.concat(shown.rows, "\n"), "F4 Open request")
                local badge, card = false, false
                for _, hit in ipairs(shown.tabs) do
                    if hit.action == "attention" then
                        test.eq(hit.id, "inbox")
                        if hit.y == nil or hit.y == 1 then badge = true else card = true end
                    end
                end
                test.is_true(badge and card)
                test.eq(scene.focus, occupied and "agent" or "inbox")
            end
        end)
        test.it("keeps the badge on a narrow desktop and clips request text", function()
            local scene = model.new(40, 12)
            local shown = render.draw(scene, {}, {}, nil, nil, "", "Workspace", appearance.defaults(),
                {alert = {id = "inbox", count = 1, title = "Approve\27]52;injected", approval_id = "request"}})
            test.contains(shown.rows[1], "! 1 Needs you")
            test.is_nil((table.concat(shown.rows):find("\27]52", 1, true)))
        end)
    end)
end
return test.run_cases(define_tests)
