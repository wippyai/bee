local test = require("test")
local state = require("state")
local commands = require("commands")

local function command(op: string, value: table?): commands.Command
    local result: table = {version = 1, op = op}
    if value then for key, item in pairs(value) do result[key] = item end end
    local decoded = commands.decode(result)
    assert(decoded)
    return decoded
end

local function define_tests()
    test.describe("Authoritative desktop state", function()
        test.it("keeps tab order stable while scene stacking changes", function()
            local current = state.new(80, 24)
            current = state.reduce(current, command("add", {id = "one", instance_id = "a", title = "One"}))
            current = state.reduce(current, command("add", {id = "two", instance_id = "b", title = "Two"}))
            test.eq(current.tabs[1], "one")
            test.eq(current.tabs[2], "two")

            current = state.reduce(current, command("focus", {id = "one"}))
            test.eq(current.tabs[1], "one")
            test.eq(current.tabs[2], "two")
            test.eq(current.scene.windows[#current.scene.windows].id, "one")
        end)

        test.it("owns preferences and advances the scene revision", function()
            local current = state.new(80, 24)
            local initial = current.scene.revision
            current = state.reduce(current, command("appearance", {theme = "ocean", background = "grid"}))
            test.eq(current.preferences.theme, "ocean")
            test.eq(current.preferences.background, "grid")
            test.eq(current.scene.revision, initial + 1)

            local repeated = state.reduce(current, command("appearance", {theme = "ocean", background = "grid"}))
            test.eq(repeated.scene.revision, current.scene.revision)
        end)

        test.it("rejects stale preference revisions without mutating state", function()
            local current = state.new(80, 24)
            current = state.reduce(current, command("appearance", {
                theme = "ocean", background = "grid", expected_revision = 99,
            }))
            test.eq(current.preferences.theme, "honey")
            test.eq(current.scene.revision, 0)
        end)

        test.it("returns defensive envelopes", function()
            local current = state.new(80, 24)
            current = state.reduce(current, command("add", {id = "one", instance_id = "a", title = "One"}))
            local envelope = state.envelope(current)
            envelope.tabs[1] = "changed"
            envelope.preferences.theme = "ocean"
            envelope.scene.windows[1].title = "Changed"
            test.eq(current.tabs[1], "one")
            test.eq(current.preferences.theme, "honey")
            test.eq(current.scene.windows[1].title, "One")
        end)

        test.it("removes a tab with its window while preserving other order", function()
            local current = state.new(80, 24)
            current = state.reduce(current, command("add", {id = "one", instance_id = "a", title = "One"}))
            current = state.reduce(current, command("add", {id = "two", instance_id = "b", title = "Two"}))
            current = state.reduce(current, command("remove", {id = "one"}))
            test.eq(#current.tabs, 1)
            test.eq(current.tabs[1], "two")
            test.eq(#current.scene.windows, 1)
            test.eq(current.scene.windows[1].id, "two")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
