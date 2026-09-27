-- MIT. Session choices belong to the owner contract; native code presents the result.
local test = require("test")
local policy = require("session_policy")
local protocol = require("protocol")

local DEFAULT = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local OTHER = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local FIRST = "cccccccccccccccccccccccccccccccc"
local SECOND = "dddddddddddddddddddddddddddddddd"

local function define_tests()
    test.describe("Hive desktop session policy", function()
        test.it("uses the owner's default workspace and its first display", function()
            local plan, err = policy.resolve(DEFAULT, {kind = "automatic", mode = "control", desktops = {FIRST, SECOND}, excluded = {}})
            test.is_nil(err)
            test.eq(plan and plan.kind, "attach")
            test.eq(plan and plan.workspace_id, DEFAULT)
            test.eq(plan and plan.desktop_id, FIRST)
        end)

        test.it("requests a workspace when the owner has no default", function()
            local plan, err = policy.resolve(nil, {kind = "automatic", mode = "control", desktops = {FIRST}, excluded = {}})
            test.is_nil(err)
            test.eq(plan and plan.kind, "choose_workspace")
        end)

        test.it("reuses the next display and allocates only after controlled displays", function()
            local next_plan, next_error = policy.resolve(DEFAULT, {
                kind = "workspace", workspace_id = OTHER, mode = "control", desktops = {FIRST, SECOND}, excluded = {FIRST},
            })
            test.is_nil(next_error)
            test.eq(next_plan and next_plan.kind, "attach")
            test.eq(next_plan and next_plan.workspace_id, OTHER)
            test.eq(next_plan and next_plan.desktop_id, SECOND)

            local allocation, allocation_error = policy.resolve(DEFAULT, {
                kind = "workspace", workspace_id = OTHER, mode = "control", desktops = {FIRST, SECOND}, excluded = {FIRST, SECOND},
            })
            test.is_nil(allocation_error)
            test.eq(allocation and allocation.kind, "allocate")
            test.eq(allocation and allocation.workspace_id, OTHER)
        end)

        test.it("keeps an explicit display exact and does not allocate for observers", function()
            local selected, selected_error = policy.resolve(DEFAULT, {
                kind = "selection", workspace_id = OTHER, desktop_id = SECOND, mode = "observe", desktops = {FIRST, SECOND},
            })
            test.is_nil(selected_error)
            test.eq(selected and selected.kind, "attach")
            test.eq(selected and selected.workspace_id, OTHER)
            test.eq(selected and selected.desktop_id, SECOND)

            local absent, absent_error = policy.resolve(DEFAULT, {
                kind = "workspace", workspace_id = OTHER, mode = "observe", desktops = {FIRST}, excluded = {FIRST},
            })
            test.is_nil(absent)
            test.eq(absent_error, "selected owner has no display to observe")
        end)

        test.it("decodes plan requests as exact discriminated contracts", function()
            local valid = protocol.input(protocol.PLAN, {
                owner_execution = DEFAULT,
                request = {kind = "automatic", mode = "control", desktops = {FIRST}, excluded = {}},
            })
            test.eq(valid and valid.kind, "plan")
            test.eq(valid and valid.kind == "plan" and valid.request.kind, "automatic")

            local extra = protocol.input(protocol.PLAN, {
                owner_execution = DEFAULT,
                extra = true,
                request = {kind = "automatic", mode = "control", desktops = {FIRST}, excluded = {}},
            })
            test.is_nil(extra)

            local unknown_desktop = protocol.input(protocol.PLAN, {
                owner_execution = DEFAULT,
                request = {kind = "workspace", workspace_id = OTHER, mode = "control", desktops = {FIRST}, excluded = {SECOND}},
            })
            test.is_nil(unknown_desktop)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
