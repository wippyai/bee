-- MIT
local test = require("test")
local copy = require("copy")
local model = require("model")

local BODY: model.Rect = {x = 11, y = 6, width = 30, height = 4}
local ROWS = {"open /srv/me1/a.lua now", "commit 6d36a9f1c landed", "Error: the node cannot start", ""}

local function mouse(action: string, x: integer, y: integer, button: string?): {[string]: unknown}
    return {type = "mouse", action = action, button = button or "left", x = BODY.x + x - 1, y = BODY.y + y - 1,
        ctrl = false, alt = false, shift = false}
end

local function key(name: string, modifiers: {[string]: boolean}?): {[string]: unknown}
    local event: {[string]: unknown} = {type = "key", key = name, key_type = #name == 1 and "runes" or name, action = "press",
        ctrl = false, alt = false, shift = false}
    for flag, value in pairs(modifiers or {}) do event[flag] = value end
    return event
end

local function press(ctl: copy.Controller, x: integer, y: integer, drags: boolean?): copy.Outcome
    return copy.pointer(ctl, "win", BODY, ROWS, mouse("press", x, y) :: any, drags == true)
end

local function feed(ctl: copy.Controller, event: {[string]: unknown}): copy.Outcome
    return copy.input(ctl, event :: any, BODY)
end

local function typed(ctl: copy.Controller, letters: string): copy.Outcome
    local outcome: copy.Outcome = {forward = {}}
    for character in letters:gmatch(".") do outcome = feed(ctl, key(character)) end
    return outcome
end

local function define_tests()
    test.describe("Copying text out of windows", function()
        test.it("gives a click without motion to the app as press and release, in body cells", function()
            local ctl = copy.new()
            local held = press(ctl, 3, 2)
            test.eq(#held.forward, 0)
            test.is_true(copy.engaged(ctl))
            local stayed = feed(ctl, mouse("motion", 3, 2))
            test.eq(#stayed.forward, 0)
            local released = feed(ctl, mouse("release", 3, 2))
            test.eq(#released.forward, 2)
            test.eq(released.forward[1].action, "press"); test.eq(released.forward[1].x, 3); test.eq(released.forward[1].y, 2)
            test.eq(released.forward[2].action, "release")
            test.is_nil(released.copy)
            test.is_false(copy.engaged(ctl))
        end)

        test.it("selects with a drag, bounded to the window, and copies on release", function()
            local ctl = copy.new()
            press(ctl, 6, 1)
            feed(ctl, mouse("motion", 12, 1))
            local overlay = copy.overlay(ctl)
            test.not_nil(overlay)
            if overlay then
                test.eq(overlay.id, "win")
                test.eq(overlay.marks[1].role, "selection"); test.eq(overlay.marks[1].first, 6); test.eq(overlay.marks[1].last, 12)
            end
            local outcome = feed(ctl, mouse("release", 19, 1))
            test.eq(outcome.copy, "/srv/me1/a.lua")
            test.eq(#outcome.forward, 0)
            test.is_false(copy.engaged(ctl))

            press(ctl, 8, 2)
            feed(ctl, mouse("motion", 9, 2))
            outcome = feed(ctl, mouse("release", -40, 99))
            test.eq(outcome.copy, "6d36a9f1c landed\nError: the node cannot start\n")
        end)

        test.it("gives the app both clicks of a double click and copies nothing", function()
            local ctl = copy.new()
            for _ = 1, 2 do
                local held = press(ctl, 10, 2)
                test.eq(#held.forward, 0)
                test.is_nil(held.copy)
                local released = feed(ctl, mouse("release", 10, 2))
                test.eq(#released.forward, 2)
                test.eq(released.forward[1].action, "press"); test.eq(released.forward[1].x, 10); test.eq(released.forward[1].y, 2)
                test.eq(released.forward[2].action, "release"); test.eq(released.forward[2].x, 10); test.eq(released.forward[2].y, 2)
                test.is_nil(released.copy)
                test.is_false(copy.engaged(ctl))
            end
        end)

        test.it("leaves every pointer event to an app that takes drags", function()
            local ctl = copy.new()
            local outcome = press(ctl, 4, 1, true)
            test.eq(#outcome.forward, 1)
            test.eq(outcome.forward[1].x, 4)
            test.is_false(copy.engaged(ctl))
            local wheel = copy.pointer(ctl, "win", BODY, ROWS, mouse("wheel", 4, 1, "wheel_up") :: any, false)
            test.eq(#wheel.forward, 1)
        end)

        test.it("hands a key during a held press on after giving the app its press", function()
            local ctl = copy.new()
            press(ctl, 1, 1)
            local outcome = feed(ctl, key("x"))
            test.is_true(outcome.pass == true)
            test.eq(#outcome.forward, 1)
            test.is_false(copy.engaged(ctl))
        end)

        test.it("labels tokens for quick copy and copies the one whose hint is typed", function()
            local ctl = copy.new()
            local started = copy.begin(ctl, "hints", "win", BODY, ROWS)
            test.eq(started.status, copy.HINT_STATUS)
            local overlay = copy.overlay(ctl)
            test.not_nil(overlay)
            local labels: {[string]: string} = {}
            if overlay then
                for _, item in ipairs(overlay.marks) do
                    if item.role == "label" then labels[tostring(item.y) .. ":" .. tostring(item.first)] = tostring(item.text) end
                end
            end
            test.eq(labels["3:1"], "a")
            test.eq(labels["2:8"], "s")
            test.eq(labels["1:6"], "d")
            local miss = typed(ctl, "z")
            test.not_nil(miss.status)
            test.is_true(copy.engaged(ctl))
            local chosen = typed(ctl, "s")
            test.eq(chosen.copy, "6d36a9f1c")
            test.is_false(copy.engaged(ctl))

            copy.begin(ctl, "hints", "win", BODY, ROWS)
            feed(ctl, key("esc"))
            test.is_false(copy.engaged(ctl))
            local empty = copy.begin(ctl, "hints", "win", BODY, {"plain words only"})
            test.is_false(copy.engaged(ctl))
            test.not_nil(empty.status)
        end)

        test.it("moves a cursor in copy mode and copies a character or line range", function()
            local ctl = copy.new()
            copy.begin(ctl, "cursor", "win", BODY, ROWS)
            local overlay = copy.overlay(ctl)
            if overlay then
                local cursor = overlay.marks[#overlay.marks]
                test.eq(cursor.role, "cursor"); test.eq(cursor.y, 3); test.eq(cursor.first, 1)
            end
            typed(ctl, "gjwwwww")
            typed(ctl, "lllllllv")
            typed(ctl, "llllllll")
            local nothing = copy.input(ctl, key("x") :: any, BODY)
            test.eq(#nothing.forward, 0)
            local outcome = typed(ctl, "y")
            test.eq(outcome.copy, "6d36a9f1c")

            copy.begin(ctl, "cursor", "win", BODY, ROWS)
            local none = typed(ctl, "y")
            test.is_nil(none.copy)
            test.is_true(copy.engaged(ctl))
            typed(ctl, "kV")
            feed(ctl, key("up"))
            outcome = feed(ctl, key("enter"))
            test.eq(outcome.copy, "open /srv/me1/a.lua now\ncommit 6d36a9f1c landed")
        end)

        test.it("starts a range in copy mode with a press and ignores the release of the click that opened it", function()
            local ctl = copy.new()
            copy.begin(ctl, "cursor", "win", BODY, ROWS)
            local stray = feed(ctl, mouse("release", 4, 1))
            test.is_nil(stray.copy)
            test.is_nil(stray.status)
            test.is_true(copy.engaged(ctl))
            feed(ctl, mouse("press", 1, 2))
            feed(ctl, mouse("motion", 6, 2))
            test.eq(feed(ctl, mouse("release", 6, 2)).copy, "commit")
            test.is_false(copy.engaged(ctl))
        end)

        test.it("searches forward and back in copy mode", function()
            local ctl = copy.new()
            copy.begin(ctl, "cursor", "win", BODY, ROWS)
            typed(ctl, "g/")
            typed(ctl, "no")
            local found = feed(ctl, key("enter"))
            test.not_nil(found.status)
            local overlay = copy.overlay(ctl)
            local function cursor(): copy.Mark?
                local value = copy.overlay(ctl)
                return value and value.marks[#value.marks] or nil
            end
            local at = cursor()
            if at then test.eq(at.y, 1); test.eq(at.first, 21) end
            typed(ctl, "n")
            at = cursor()
            if at then test.eq(at.y, 3); test.eq(at.first, 12) end
            typed(ctl, "N")
            at = cursor()
            if at then test.eq(at.y, 1); test.eq(at.first, 21) end
            test.not_nil(overlay)
            typed(ctl, "v$")
            test.eq(typed(ctl, "y").copy, "now")
            copy.begin(ctl, "cursor", "win", BODY, ROWS)
            feed(ctl, key("esc"))
            test.is_false(copy.engaged(ctl))
        end)

        test.it("ends a selection whose window changed size or went away", function()
            local ctl = copy.new()
            copy.begin(ctl, "cursor", "win", BODY, ROWS)
            local outcome = copy.input(ctl, key("j") :: any, {x = 1, y = 1, width = 10, height = 4})
            test.not_nil(outcome.status)
            test.is_false(copy.engaged(ctl))
            copy.begin(ctl, "cursor", "win", BODY, ROWS)
            copy.input(ctl, key("j") :: any, nil)
            test.is_false(copy.engaged(ctl))
        end)

        test.it("reports what it copied in characters, or why it could not", function()
            test.eq(copy.report("héllo", true, nil), "Copied 5 characters")
            test.eq(copy.report("x", true, nil), "Copied 1 character")
            test.eq(copy.report("x", false, "unsupported"), "Copy failed: unsupported")
        end)

        test.it("finds the body of a shown window and none for a collapsed one", function()
            local scene = model.add(model.new(100, 30), "win", "win", "Probe")
            local body = copy.body(scene, "win")
            test.not_nil(body)
            test.is_nil(copy.body(scene, "other"))
            test.is_nil(copy.body(model.collapse(scene, "win"), "win"))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
