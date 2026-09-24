local test = require("test")
local model = require("model")
local decode = require("decode")

local function inside(rect: model.Rect, width: integer, height: integer): boolean
    local top = height >= 3 and 2 or 1
    local bottom = height >= 3 and height - 1 or height
    return rect.x >= 1 and rect.y >= top
        and rect.x + rect.width <= width + 1
        and rect.y + rect.height <= bottom + 1
end

local function window(scene: model.Scene, id: string): model.Window
    for index = 1, #scene.windows do
        if scene.windows[index].id == id then return scene.windows[index] end
    end
    error("missing window " .. id)
end

local function define_tests()
    test.describe("Application title announcements", function()
        test.it("preserves user labels, rejects a stale instance and reveals the latest title on clear", function()
            local scene = model.add(model.new(80, 24), "view", "instance", "Original")
            scene = model.personalize(scene, "view", "Pinned", "rose")
            local next_scene = model.announce(scene, "view", "instance", "Current")
            test.eq(model.display_title(next_scene.windows[1]), "Pinned")
            test.eq(next_scene.windows[1].title, "Current")
            test.eq(next_scene.windows[1].accent, "rose")
            test.eq(model.announce(next_scene, "view", "stale", "Bad"), next_scene)
            test.eq(model.announce(next_scene, "view", "instance", "Current"), next_scene)
            local cleared = model.personalize(next_scene, "view", "", "rose")
            test.eq(model.display_title(cleared.windows[1]), "Current")
            test.eq(scene.windows[1].title, "Original")
        end)
    end)
    test.describe("Bee desktop model", function()
        test.it("creates bounded windows and keeps transforms immutable", function()
            local empty = model.new(80, 24)
            local scene = model.add(empty, "window-1", "instance-1", "Terminal")
            local added = window(scene, "window-1")

            test.eq(empty.revision, 0)
            test.eq(#empty.windows, 0)
            test.eq(scene.revision, 1)
            test.eq(scene.focus, "window-1")
            test.eq(added.mode, "floating")
            test.eq(added.restore_mode, "floating")
            test.is_nil(added.user_title)
            test.is_nil(added.accent)
            test.eq(model.display_title(added), "Terminal")
            test.is_true(inside(added.bounds, scene.width, scene.height))
            test.is_true(added.bounds.y >= 2)
            test.eq(added.normal_bounds.y, added.bounds.y)
        end)

        test.it("sizes a new window to the display", function()
            local wide = window(model.add(model.new(120, 36), "terminal", "instance", "Terminal"), "terminal")
            test.eq(wide.bounds.width, 90)
            test.eq(wide.bounds.height, 26)
            local standard = window(model.add(model.new(80, 24), "terminal", "instance", "Terminal"), "terminal")
            test.eq(standard.bounds.width, 64)
            test.eq(standard.bounds.height, 20)
        end)

        test.it("uses every cascade slot before reusing a window position", function()
            local scene = model.new(77, 24)
            local positions: {[string]: boolean} = {}
            for index = 1, 8 do
                local id = "window-" .. tostring(index)
                scene = model.add(scene, id, "instance-" .. tostring(index), "Window")
                local bounds = window(scene, id).bounds
                local position = tostring(bounds.x) .. ":" .. tostring(bounds.y)
                test.is_nil(positions[position])
                positions[position] = true
            end
        end)

        test.it("personalizes bounded display data without changing identity or focus", function()
            local scene = model.add(model.new(80, 24), "one", "instance-one", "Announced")
            scene = model.add(scene, "two", "instance-two", "Other")
            local personalized = model.personalize(scene, "one", "My Window", "cyan")
            local changed = window(personalized, "one")

            test.eq(changed.id, "one")
            test.eq(changed.instance_id, "instance-one")
            test.eq(changed.title, "Announced")
            test.eq(changed.user_title, "My Window")
            test.eq(changed.accent, "cyan")
            test.eq(model.display_title(changed), "My Window")
            test.eq(personalized.focus, scene.focus)
            test.eq(personalized.revision, scene.revision + 1)

            local repeated = model.personalize(personalized, "one", "My Window", "cyan")
            test.eq(repeated.revision, personalized.revision)

            local focused = model.focus(personalized, "one")
            local focused_window = window(focused, "one")
            test.eq(focused_window.user_title, "My Window")
            test.eq(focused_window.accent, "cyan")

            local cleared = model.personalize(focused, "one", "", "")
            local cleared_window = window(cleared, "one")
            test.is_nil(cleared_window.user_title)
            test.is_nil(cleared_window.accent)
            test.eq(model.display_title(cleared_window), "Announced")
            test.eq(cleared_window.title, "Announced")
        end)

        test.it("preserves optional personalization through scene decoding", function()
            local scene = model.add(model.new(80, 24), "one", "instance-one", "Announced")
            scene = model.personalize(scene, "one", "Custom", "rose")
            local decoded = decode.scene(scene)
            test.not_nil(decoded)
            if decoded then
                test.eq(decoded.windows[1].title, "Announced")
                test.eq(decoded.windows[1].user_title, "Custom")
                test.eq(decoded.windows[1].accent, "rose")
                decoded.windows[1].user_title = "Changed"
                test.eq(scene.windows[1].user_title, "Custom")
            end

            local legacy = decode.scene(model.add(model.new(80, 24), "old", "instance-old", "Old"))
            test.not_nil(legacy)
            if legacy then
                test.is_nil(legacy.windows[1].user_title)
                test.is_nil(legacy.windows[1].accent)
            end

            scene.windows[1].user_title = string.rep("x", 81)
            test.is_nil(decode.scene(scene))
            scene.windows[1].user_title = "line\nbreak"
            test.is_nil(decode.scene(scene))
            scene.windows[1].user_title = "Custom"
            scene.windows[1].accent = "yellow"
            test.is_nil(decode.scene(scene))
        end)

        test.it("focuses independently from fullscreen mode", function()
            local scene = model.add(model.new(80, 24), "one", "a", "One")
            scene = model.add(scene, "two", "b", "Two")
            local full = model.toggle_fullscreen(scene, "one")
            local focused = model.focus(full, "two")

            test.eq(window(full, "one").mode, "fullscreen")
            test.eq(focused.focus, "two")
            test.eq(window(focused, "one").mode, "fullscreen")
            test.eq(window(focused, "two").mode, "floating")
            test.eq(window(full, "one").normal_bounds.x, window(focused, "one").normal_bounds.x)
        end)

        test.it("shows one fullscreen layer and raises focused floating windows", function()
            local scene = model.new(80, 24)
            scene = model.add(scene, "one", "a", "One")
            scene = model.add(scene, "two", "b", "Two")
            scene = model.add(scene, "three", "c", "Three")
            scene = model.toggle_fullscreen(scene, "one")
            scene = model.toggle_fullscreen(scene, "two")

            local selected = model.visible(scene)
            test.eq(#selected, 2)
            test.eq(selected[1].id, "two")
            test.eq(selected[2].id, "three")

            local focused = model.focus(scene, "one")
            selected = model.visible(focused)
            test.eq(#selected, 1)
            test.eq(selected[1].id, "one")

            local raised = model.focus(focused, "three")
            selected = model.visible(raised)
            test.eq(selected[1].id, "one")
            test.eq(selected[2].id, "three")
            test.eq(raised.windows[#raised.windows].id, "three")
        end)

        test.it("restores saved normal bounds after fullscreen", function()
            local scene = model.add(model.new(80, 24), "one", "a", "One")
            scene = model.place(scene, "one", { x = 13, y = 7, width = 27, height = 9 })
            local placed = window(scene, "one")
            local full = model.toggle_fullscreen(scene, "one")
            local fullscreen = window(full, "one")

            test.eq(model.bounds(full, fullscreen).x, 1)
            test.eq(model.bounds(full, fullscreen).y, 2)
            test.eq(model.bounds(full, fullscreen).height, 23)
            test.eq(fullscreen.normal_bounds.x, placed.bounds.x)
            test.eq(fullscreen.normal_bounds.width, placed.bounds.width)

            local restored = model.toggle_fullscreen(full, "one")
            local restored_window = window(restored, "one")
            test.eq(restored_window.mode, "floating")
            test.eq(restored_window.bounds.x, 13)
            test.eq(restored_window.bounds.y, 7)
            test.eq(restored_window.bounds.width, 27)
            test.eq(restored_window.bounds.height, 9)
        end)

        test.it("resizes fullscreen bounds without losing normal bounds", function()
            local scene = model.add(model.new(80, 24), "one", "a", "One")
            scene = model.place(scene, "one", { x = 50, y = 10, width = 25, height = 10 })
            local full = model.toggle_fullscreen(scene, "one")
            local resized = model.resize_screen(full, 32, 8)
            local changed = window(resized, "one")

            test.eq(resized.width, 32)
            test.eq(resized.height, 8)
            test.eq(changed.bounds.x, 1)
            test.eq(changed.bounds.y, 2)
            test.eq(changed.bounds.width, 32)
            test.eq(changed.bounds.height, 7)
            test.eq(changed.normal_bounds.x, 50)
            test.eq(changed.normal_bounds.y, 10)
            test.eq(window(full, "one").normal_bounds.x, 50)
        end)

        test.it("restores floating geometry after temporary terminal shrink", function()
            local original = model.add(model.new(100, 30), "one", "a", "One")
            local tiny = model.resize_screen(original, 1, 1)
            test.eq(window(tiny, "one").bounds.width, 1)
            local restored = model.resize_screen(tiny, 100, 30)
            test.eq(window(restored, "one").bounds.width, window(original, "one").bounds.width)
            test.eq(window(restored, "one").bounds.x, window(original, "one").bounds.x)
        end)

        test.it("minimizes and focuses back into the remembered fullscreen mode", function()
            local scene = model.add(model.new(80, 24), "one", "a", "One")
            scene = model.add(scene, "two", "b", "Two")
            scene = model.place(scene, "one", { x = 13, y = 7, width = 27, height = 9 })
            scene = model.toggle_fullscreen(scene, "one")

            local minimized = model.minimize(scene, "one")
            local parked = window(minimized, "one")
            test.eq(parked.mode, "minimized")
            test.eq(parked.restore_mode, "fullscreen")
            test.eq(parked.normal_bounds.x, 13)
            test.eq(parked.normal_bounds.height, 9)
            test.eq(minimized.focus, "two")

            local focused = model.focus(minimized, "one")
            local restored = window(focused, "one")
            test.eq(focused.focus, "one")
            test.eq(restored.mode, "fullscreen")
            test.eq(restored.restore_mode, "fullscreen")
            test.eq(restored.bounds.x, 1)
            test.eq(restored.bounds.y, 2)
            test.eq(restored.normal_bounds.x, 13)
            test.eq(restored.normal_bounds.height, 9)

            local repeated = model.focus(focused, "one")
            test.eq(repeated.revision, focused.revision)
            test.eq(window(repeated, "one").mode, "fullscreen")
        end)

        test.it("collapses idempotently, preserves normal bounds, and snaps floating windows", function()
            local scene = model.add(model.new(80, 24), "one", "a", "One")
            scene = model.place(scene, "one", { x = 13, y = 7, width = 27, height = 9 })
            local collapsed = model.collapse(scene, "one")
            local parked = window(collapsed, "one")
            test.eq(parked.mode, "collapsed")
            test.eq(parked.restore_mode, "collapsed")
            test.eq(parked.bounds.height, 1)
            test.eq(model.bounds(collapsed, parked).height, 1)
            test.eq(parked.normal_bounds.x, 13)
            test.eq(parked.normal_bounds.height, 9)

            local repeated = model.collapse(collapsed, "one")
            test.eq(repeated.revision, collapsed.revision)

            local restored = model.restore(collapsed, "one")
            local floating = window(restored, "one")
            test.eq(floating.mode, "floating")
            test.eq(floating.restore_mode, "floating")
            test.eq(floating.bounds.x, 13)
            test.eq(floating.bounds.height, 9)
            test.eq(floating.normal_bounds.x, 13)

            local left = model.snap(restored, "one", "left")
            local left_window = window(left, "one")
            test.eq(left_window.bounds.x, 1)
            test.eq(left_window.bounds.y, 2)
            test.eq(left_window.bounds.width, 40)
            test.eq(left_window.bounds.height, 23)
            test.eq(left_window.normal_bounds.width, 40)

            local right = model.snap(left, "one", "right")
            local right_window = window(right, "one")
            test.eq(right_window.bounds.x, 41)
            test.eq(right_window.bounds.width, 40)
            local invalid = model.snap(right, "one", "middle")
            test.eq(invalid.revision, right.revision)
        end)

        test.it("moves a collapsed bar and retains its expanded dimensions", function()
            local scene = model.add(model.new(80, 24), "one", "app", "One")
            scene = model.place(scene, "one", {x = 5, y = 4, width = 20, height = 10})
            local collapsed = model.collapse(scene, "one")
            local moved = model.place(collapsed, "one", {x = 12, y = 8, width = 1, height = 1})
            test.eq(moved.windows[1].bounds.height, 1)
            test.eq(moved.windows[1].bounds.width, 20)
            test.eq(collapsed.windows[1].normal_bounds.x, 5)
            local restored = model.restore(moved, "one")
            test.eq(restored.windows[1].bounds.x, 12)
            test.eq(restored.windows[1].bounds.y, 8)
            test.eq(restored.windows[1].bounds.width, 20)
            test.eq(restored.windows[1].bounds.height, 10)
        end)
        test.it("restores minimized collapsed windows with a one-row bounds on tiny screens", function()
            local scene = model.add(model.new(8, 8), "one", "a", "One")
            scene = model.collapse(scene, "one")
            scene = model.minimize(scene, "one")
            test.eq(window(scene, "one").restore_mode, "collapsed")

            local restored = model.focus(scene, "one")
            local restored_window = window(restored, "one")
            test.eq(restored_window.mode, "collapsed")
            test.eq(model.bounds(restored, restored_window).height, 1)

            local tiny = model.resize_screen(restored, 1, 1)
            local tiny_window = window(tiny, "one")
            test.eq(model.bounds(tiny, tiny_window).x, 1)
            test.eq(model.bounds(tiny, tiny_window).y, 1)
            test.eq(model.bounds(tiny, tiny_window).width, 1)
            test.eq(model.bounds(tiny, tiny_window).height, 1)
        end)

        test.it("repairs focus on removal and bounds tiny screens", function()
            local scene = model.new(2, 2)
            scene = model.add(scene, "one", "a", "One")
            scene = model.add(scene, "two", "b", "Two")
            scene = model.focus(scene, "one")
            local minimized = model.toggle_fullscreen(scene, "two")
            minimized = model.remove(minimized, "two")

            test.eq(#model.visible(minimized), 1)
            test.eq(model.visible(minimized)[1].id, "one")
            test.eq(minimized.focus, "one")

            local tiny = model.resize_screen(minimized, 1, 1)
            test.is_true(inside(window(tiny, "one").bounds, 1, 1))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options)
    return run_cases(options)
end

return { run = run }
