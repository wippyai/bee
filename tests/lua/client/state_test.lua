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
        test.it("keeps pending target identity across empty, added and removed projections", function()
            local added = assert(state.import_desktop(first_workspace, legacy()))
            local key = added.tabs[1]
            local targets = {[key] = added.targets[1]}
            local empty = state.empty(100, 30)
            -- An initial snapshot can arrive after add and remove were queued.
            local initial = assert(state.project(empty, empty, targets))
            test.eq(#initial.targets, 0)
            test.is_true(targets[key] ~= nil)
            local visible = assert(state.project(initial, added, targets))
            test.eq(#visible.targets, 1)
            local removed = {scene = model.remove(visible.scene, key), tabs = {}, preferences = visible.preferences}
            local final = assert(state.project(visible, removed, targets))
            test.eq(#final.targets, 0)
            test.is_true(targets[key] ~= nil)
            -- A removal acknowledgement can beat the older scene channel.
            test.is_nil(state.project(final, added, targets))
            -- Owner prunes only after the correlated removal has committed.
            targets[key] = nil
            test.is_nil(state.project(initial, added, targets))
        end)
        test.it("rejects two tabs that control the same qualified producer", function()
            local imported = assert(state.import_desktop(first_workspace, legacy()))
            local duplicate = assert(state.import_desktop(first_workspace, legacy()))
            duplicate.scene.windows[1].id = "second-tab"
            duplicate.targets[1].tab_id = "second-tab"
            imported.scene.windows[2] = duplicate.scene.windows[1]
            imported.targets[2] = duplicate.targets[1]
            imported.tabs[2] = "second-tab"
            test.is_nil(state.decode(imported))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
