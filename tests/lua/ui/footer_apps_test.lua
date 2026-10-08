-- SPDX-License-Identifier: MIT
local test = require("test")
local frame = require("frame")
local appearance = require("appearance")
local picker = require("picker")
local directory = require("directory")
local settings = require("settings")
local help = require("help")
local library = require("library")
local library_model = require("library_model")
local contents = require("contents")
local inbox = require("inbox")
local inbox_model = require("inbox_model")
local leases = require("leases")
local gateway = require("gateway")
local processes = require("processes")
local process_history = require("process_history")
local process_probe = require("process_probe")
local function check(shown: frame.View, height: integer, action: string)
    test.is_true(shown.rows[height]:find(action, 1, true) ~= nil)
    test.is_nil((shown.rows[height - 1]:find(action, 1, true)))
    for _, hit in ipairs(shown.hits) do
        if hit.kind == "frame_help" or hit.kind == "frame_more" then test.eq(hit.y, height) end
    end
end
local function define_tests()
    test.describe("Application footer rows", function()
        test.it("uses one row in every application at compact and wide widths", function()
            local prefs = appearance.defaults()
            for _, width in ipairs({80, 160}) do
                check(picker.draw(width, 24, prefs, {items = {}, unavailable = 0, notes = {}}, 0, ""), 24, "Enter Open")
                check(directory.draw(width, 24, prefs, {}, 0, "", false), 24, "N Start agent")
                check(settings.draw(width, 24, prefs, {}, "about", 0), 24, "Check for updates")
                check(help.draw(width, 24, prefs, "desktop", 0), 24, "? help")
                check(library.draw(width, 24, prefs, library_model.new("workspace"),
                    {offset = 0, status = "", reading = false, editor = nil, content = contents.new()}), 24, "? help")
                check(inbox.draw(width, 24, prefs, inbox_model.new({"workspace"}), {}, 0, "", leases.new()), 24, "F10 More")
                check(gateway.draw(width, 24, prefs, {}, 0, "", nil), 24, "R Refresh")
                local snapshot: process_probe.Snapshot = {processes = {}, services = {}, host_executed = {}, error = ""}
                check(processes.draw(width, 24, snapshot, process_history.new_history(), prefs, "", 0,
                    false, "", false, false, {}, false), 24, "P Pause")
                check(processes.draw_hive(width, 24, {}, prefs, "", 0, false, ""), 24, "P Pause")
            end
        end)
    end)
end
return test.run_cases(define_tests)
