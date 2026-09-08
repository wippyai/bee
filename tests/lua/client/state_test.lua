-- MIT. The client tab key cannot substitute for a qualified application target.
local test = require("test")
local state = require("state")
local model = require("model")
local appearance = require("appearance")
local first_workspace = "0123456789abcdef0123456789abcdef"
local second_workspace = "ffffffffffffffffffffffffffffffff"
local function legacy()
    local scene = model.add(model.new(100, 30), "view", "instance", "Terminal")
    scene = model.personalize(scene, "view", "Project", "cyan")
    return {scene = scene, tabs = {"view"}, preferences = appearance.defaults()}
end
local function define_tests()
    test.describe("Client durable layout", function()
        test.it("composes equal remote IDs without losing their workspaces", function()
            local source = legacy()
            local first = assert(state.import_desktop(first_workspace, source))
            local second = assert(state.import_desktop(second_workspace, source))
            test.eq(source.scene.windows[1].id, "view")
            test.is_true(first.tabs[1] ~= second.tabs[1])
            test.eq(first.scene.focus, first.tabs[1])
            test.eq(first.scene.windows[1].user_title, "Project")
            first.scene.windows[2] = second.scene.windows[1]
            first.tabs[2] = second.tabs[1]
            first.targets[2] = second.targets[1]
            local mixed = assert(state.decode(first))
            local left = assert(state.target(mixed, mixed.tabs[1]))
            local right = assert(state.target(mixed, mixed.tabs[2]))
            test.eq(left.view_id, right.view_id)
            test.eq(left.instance_id, right.instance_id)
            test.eq(left.workspace_id, first_workspace)
            test.eq(right.workspace_id, second_workspace)
            left.workspace_id = second_workspace
            test.eq(assert(state.target(mixed, mixed.tabs[1])).workspace_id, first_workspace)
            mixed.targets[1].workspace_id = second_workspace
            test.is_nil(state.decode(mixed))
        end)
        test.it("requires exactly one consistent target for each client window", function()
            local imported = assert(state.import_desktop(first_workspace, legacy()))
            imported.targets[2] = imported.targets[1]
            test.is_nil(state.decode(imported))
            imported.targets[2] = nil
            imported.targets[1].instance_id = "another"
            test.is_nil(state.decode(imported))
            imported.targets[1].instance_id = "instance"
            imported.targets[1].view_id = ""
            test.is_nil(state.decode(imported))
            imported.targets[1].view_id = string.rep("x", 81)
            test.is_nil(state.decode(imported))
        end)
        test.it("refuses foreign legacy windows and generates stable import keys", function()
            local source = legacy()
            local first = assert(state.import_desktop(first_workspace, source))
            local retry = assert(state.import_desktop(first_workspace, source))
            test.eq(first.tabs[1], retry.tabs[1])
            source.scene.windows[1].workspace_id = second_workspace
            test.is_nil(state.import_desktop(first_workspace, source))
            test.is_nil(state.import_desktop("invalid", legacy()))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
