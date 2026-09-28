-- MIT. Every reference application in docs/reference/apps compiles against the
-- public application library and draws inside a canvas at each size class:
-- one row per canvas row at the canvas width and hits inside the canvas.
local test = require("test")
local tty = require("tty")
local frame = require("frame")
local forms = require("forms")
local appearance = require("appearance")
local deploy_board = require("deploy_board")
local ci_bench = require("ci_bench")
local inbox = require("inbox")
local log_viewer = require("log_viewer")
local topology = require("topology")
local workflow = require("workflow")
local metrics = require("metrics")
local deploy_form = require("deploy_form")
local overlays = require("overlays")

type Size = {width: integer, height: integer}
local SIZES: {Size} = {{width = 60, height = 20}, {width = 80, height = 24}, {width = 120, height = 36}, {width = 160, height = 48}}

local function plain(row: string): string
    local value = row:gsub("\27%[[0-9;]*m", "")
    return value
end

local function screen(size: Size, draw: (frame.Painter, frame.Rect) -> ()): frame.Painter
    local painter = frame.new(size.width, size.height, appearance.defaults())
    draw(painter, frame.layout(painter, true, true).work)
    local rows = frame.rows(painter)
    test.eq(#rows, size.height)
    for _, row in ipairs(rows) do test.eq(tty.text.width(row), size.width) end
    for _, hit in ipairs(painter.hits) do
        test.is_true(hit.x >= 1 and hit.y >= 1)
        test.is_true(hit.x + hit.width - 1 <= size.width and hit.y + hit.height - 1 <= size.height)
    end
    return painter
end

local function contains(painter: frame.Painter, needle: string): boolean
    for _, row in ipairs(frame.rows(painter)) do
        if plain(row):find(needle, 1, true) then return true end
    end
    return false
end

local function key(name: string, character: string?): {[string]: unknown}
    return {type = "key", action = "press", key_type = name, key = character or name}
end

local function define_tests()
    test.describe("Reference applications", function()
        test.it("draw every application class at every size class", function()
            for _, size in ipairs(SIZES) do
                screen(size, function(painter, work) deploy_board.draw(painter, work, deploy_board.sample()) end)
                screen(size, function(painter, work) ci_bench.draw(painter, work, ci_bench.sample()) end)
                screen(size, function(painter, work) inbox.draw(painter, work, inbox.sample()) end)
                screen(size, function(painter, work) log_viewer.draw(painter, work, log_viewer.sample(240)) end)
                screen(size, function(painter, work) topology.draw(painter, work, topology.sample()) end)
                screen(size, function(painter, work) workflow.draw(painter, work, workflow.sample()) end)
                local live = metrics.new()
                for _ = 1, 24 do metrics.sample(live) end
                screen(size, function(painter, work) metrics.draw(painter, work, live) end)
                screen(size, function(painter, work) deploy_form.draw(painter, work, deploy_form.new()) end)
            end
        end)

        test.it("shows the selected run and its detail on a roomy canvas", function()
            local base = deploy_board.sample()
            local model: deploy_board.Model = {runs = base.runs, selected = 4, offset = 0, tick = 0}
            local painter = screen({width = 120, height = 36}, function(p, work) deploy_board.draw(p, work, model) end)
            test.is_true(contains(painter, "IMAGE-PROXY"))
            test.is_true(contains(painter, "PIPELINE"))
            local hit = frame.hit(painter.hits, 6, 10)
            test.eq(hit and hit.kind or "", "run")
        end)

        test.it("commits an inbox decision and keeps the selection in range", function()
            local model = inbox.sample()
            model.selected = #model.requests
            local first = model.requests[model.selected].request
            test.eq(inbox.decide(model, true), "Approved: " .. first)
            test.eq(model.selected, #model.requests)
            test.eq(#model.requests, 2)
            inbox.decide(model, false)
            inbox.decide(model, false)
            test.is_nil(inbox.decide(model, true))
        end)

        test.it("advances live series only when the cadence is due", function()
            local model = metrics.new()
            test.is_true(metrics.tick(model, 0))
            test.is_false(metrics.tick(model, 500))
            test.is_true(metrics.tick(model, 1000))
            test.eq(model.step, 2)
        end)

        test.it("validates each wizard step and confirms once", function()
            local model = deploy_form.new()
            model.target.fields[1].text.value = ""
            test.is_nil(deploy_form.key(model, key("enter")))
            test.eq(model.step, 1)
            model.target.fields[1].text.value = "edge-api"
            deploy_form.key(model, key("enter"))
            deploy_form.key(model, key("enter"))
            test.eq(model.step, 3)
            deploy_form.key(model, key("enter"))
            test.is_true(model.confirming)
            local painter = screen({width = 120, height = 36}, function(p, work) deploy_form.draw(p, work, model) end)
            test.is_true(contains(painter, "Deploy edge-api"))
            test.eq(deploy_form.key(model, key("enter")), "done")
            test.is_false(model.confirming)
        end)

        test.it("drives the palette, the confirmation and the toast", function()
            local commands = {"Deploy edge-api", "Open inbox", "Show logs"}
            local model = overlays.new()
            overlays.open(model, "palette")
            overlays.key(model, key("char", "i"), commands)
            overlays.key(model, key("char", "n"), commands)
            local painter = screen({width = 80, height = 24}, function(p: frame.Painter, _: frame.Rect) overlays.draw(p, model, commands, "Deploy", "Roll out?") end)
            test.is_true(contains(painter, "Open inbox"))
            test.eq(overlays.key(model, key("enter"), commands), "Open inbox")
            test.eq(model.kind, "")

            overlays.open(model, "confirm")
            test.is_nil(overlays.key(model, key("esc"), commands))
            test.eq(model.kind, "")
            overlays.open(model, "confirm")
            test.eq(overlays.key(model, key("enter"), commands), "confirm")

            overlays.notify(model, "Saved", 2)
            local toasted = screen({width = 80, height = 24}, function(p: frame.Painter, _: frame.Rect) overlays.draw(p, model, commands, "Deploy", "Roll out?") end)
            test.is_true(contains(toasted, "Saved"))
            test.is_false(overlays.tick(model))
            test.is_true(overlays.tick(model))
            test.is_nil(model.toast)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
