-- MIT. Binding snapshots cannot retain authority or resurrect removed tabs.
local test = require("test")
local bindings = require("bindings")
local model = require("model")
local statuses = require("statuses")
local reader = require("reader")
local funcs = require("funcs")
local workspace = "0123456789abcdef0123456789abcdef"
local function snapshot(revision: integer): bindings.Snapshot
    return {version = 1, workspace_id = workspace, revision = revision,
        items = {{tab_id = "tab", instance_id = "instance", thread_id = "thread"}}}
end
local function scene(): model.Scene
    return model.add(model.new(80, 24), "tab", "instance", "App", nil, workspace)
end
local function define_tests()
    test.describe("Session thread bindings", function()
        test.it("shares a reader across tabs and retires it only after the last binding disappears", function()
            local state = statuses.new(function(_: reader.Intent): (funcs.Future?, string?)
                return nil, "offline"
            end)
            local desktop: model.Scene = scene()
            local second = scene().windows[1]
            second.id, second.instance_id = "tab-two", "instance-two"
            second.mode = "minimized"
            desktop.windows[2] = second
            local value = snapshot(1)
            value.items[2] = {tab_id = "tab-two", instance_id = "instance-two", thread_id = "thread"}
            test.is_true(statuses.apply(state, value, desktop, workspace, 0))
            local shared = assert(state.readers["thread"])
            test.eq(#statuses.values(state), 2)
            value.revision = 2
            test.is_true(statuses.apply(state, value, desktop, workspace, 1))
            test.eq(state.readers["thread"], shared)
            test.is_false(shared.closed)
            desktop.windows = {second}
            statuses.layout(state, desktop, workspace, 2)
            test.eq(state.readers["thread"], shared)
            test.eq(#statuses.values(state), 1)
            desktop.windows = {}
            statuses.layout(state, desktop, workspace, 3)
            test.is_true(shared.closed)
            test.is_nil(state.readers["thread"])
            statuses.close(state)
            test.is_false(statuses.apply(state, snapshot(3), scene(), workspace, 4))
        end)
        test.it("rejects authority fields and malformed collections", function()
            test.is_nil(bindings.decode({version = 1, workspace_id = workspace, revision = 1, items = {}, scope = "admin"}))
            test.is_nil(bindings.decode({version = 1, workspace_id = workspace, revision = 1,
                items = {{tab_id = "tab", instance_id = "instance", thread_id = "thread", actor = "owner"}}}))
            local value = snapshot(1)
            value.items[2] = value.items[1]
            test.is_nil(bindings.decode(value))
            value.items = {{tab_id = "tab", instance_id = "instance", thread_id = ""}}
            test.is_nil(bindings.decode(value))
            value.items = {[2] = {tab_id = "tab", instance_id = "instance"}}
            test.is_nil(bindings.decode(value))
            value.items = {}
            for index = 1, 17 do value.items[index] = {tab_id = tostring(index), instance_id = "instance"} end
            test.is_nil(bindings.decode(value))
        end)
        test.it("copies values and fences a delayed pre-removal snapshot", function()
            local raw = snapshot(1)
            local decoded = assert(bindings.decode(raw))
            raw.items[1].thread_id = "changed"
            test.eq(decoded.items[1].thread_id, "thread")
            local desktop: model.Scene = scene()
            local current = assert(bindings.apply(bindings.new(), decoded, desktop, workspace))
            test.eq(#current.items, 1)
            local empty = snapshot(2); empty.items = {}
            current = assert(bindings.apply(current, empty, desktop, workspace))
            test.eq(#current.items, 0)
            test.is_nil(bindings.apply(current, decoded, desktop, workspace))
            test.is_nil(bindings.apply(current, snapshot(3), desktop, "ffffffffffffffffffffffffffffffff"))
        end)
        test.it("drops mismatched instances and does not revive them on later layout changes", function()
            local desktop: model.Scene = scene()
            desktop.windows[1].instance_id = "replacement"
            local current = assert(bindings.apply(bindings.new(), snapshot(1), desktop, workspace))
            test.eq(#current.items, 0)
            desktop.windows[1].instance_id = "instance"
            test.eq(#bindings.prune(current.items, desktop, workspace), 0)
            current = assert(bindings.apply(current, snapshot(2), desktop, workspace))
            test.eq(#current.items, 1)
            desktop.windows = {}
            test.eq(#bindings.prune(current.items, desktop, workspace), 0)
        end)
    end)
end
return require("test").run_cases(define_tests)
