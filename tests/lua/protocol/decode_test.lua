local test = require("test")
local decode = require("decode")
local model = require("model")
local function define_tests()
    test.describe("Process boundary decoding", function()
        test.it("rejects malformed replies rather than coercing authority fields", function()
            test.is_nil(decode.reply(nil))
            test.is_nil(decode.reply({op = "open", mount = 123}))
            test.is_nil(decode.reply({request_id = "1", op = "open", id = "a", instance_id = "b",
                title = "A", mount = "m", error = false}))
        end)
        test.it("rejects sparse windows, duplicate identities and missing focus", function()
            local scene = model.add(model.new(80, 24), "view", "instance", "Title")
            scene.focus = "missing"
            test.is_nil(decode.scene(scene))
            scene.focus = "view"
            scene.windows[2] = scene.windows[1]
            test.is_nil(decode.scene(scene))
            local sparse = {width = 80, height = 24, revision = 1, focus = "view", windows = {[2] = scene.windows[1]}}
            test.is_nil(decode.scene(sparse))
        end)
        test.it("copies accepted scenes and rejects invalid geometry", function()
            local scene = model.add(model.new(80, 24), "view", "instance", "Title")
            local decoded = decode.scene(scene)
            test.not_nil(decoded)
            if decoded then
                decoded.windows[1].title = "Changed"
                test.eq(scene.windows[1].title, "Title")
            end
            scene.windows[1].bounds.width = 0
            test.is_nil(decode.scene(scene))
            test.is_nil(decode.scene({width = 0/0, height = 24, revision = 0, focus = "", windows = {}}))
        end)
        test.it("preserves restoration state and rejects hidden focus", function()
            local scene = model.add(model.new(80, 24), "view", "instance", "Title")
            scene = model.toggle_fullscreen(scene, "view")
            scene = model.minimize(scene, "view")
            local decoded = decode.scene(scene)
            test.not_nil(decoded)
            if decoded then
                local restored = model.focus(decoded, "view")
                test.eq(restored.windows[1].mode, "fullscreen")
            end
            scene.focus = "view"
            test.is_nil(decode.scene(scene))
        end)
        test.it("validates acknowledgements and copies their committed scene", function()
            local scene = model.add(model.new(80, 24), "view", "instance", "Title")
            test.is_nil(decode.ack(nil))
            test.is_nil(decode.ack({request_id = 1, scene = scene}))
            test.is_nil(decode.ack({request_id = string.rep("x", 81), scene = scene}))
            test.is_nil(decode.ack({request_id = "focus", scene = {}}))
            local ack = decode.ack({version = 1, request_id = "focus", scene = scene, tabs = {"view"}, error_code = "", error = ""})
            test.not_nil(ack)
            if ack then
                test.eq(ack.request_id, "focus")
                test.eq(ack.scene.revision, scene.revision)
                ack.scene.windows[1].title = "Changed"
                test.eq(scene.windows[1].title, "Title")
            end
        end)
        test.it("validates stable tab order independently from stacking", function()
            local scene = model.add(model.new(80, 24), "one", "a", "One")
            scene = model.add(scene, "two", "b", "Two")
            local state = decode.desktop({scene = scene, tabs = {"two", "one"}})
            test.not_nil(state)
            if state then test.eq(state.tabs[1], "two") end
            test.is_nil(decode.desktop({scene = scene, tabs = {"one", "one"}}))
            test.is_nil(decode.desktop({scene = scene, tabs = {"one"}}))
            test.is_nil(decode.desktop({scene = scene, tabs = {[2] = "two", [3] = "one"}}))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
