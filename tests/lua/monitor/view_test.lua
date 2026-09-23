-- MIT. The reference dashboard keeps every row and target inside the canvas
-- at every size, adds panels only at the size-class breakpoints, names every
-- state in words and keeps a failed source inside its own panel.
local test = require("test")
local tty = require("tty")
local frame = require("frame")
local viz = require("viz")
local probe = require("probe")
local view = require("view")
local appearance = require("appearance")

local function sample(step: integer): probe.Snapshot
    local processes: {probe.Process} = {}
    local hosts: {string} = {"bee:workers", "bee:terminal", "bee:host"}
    local states: {string} = {"running", "idle", "idle", "waiting"}
    for index = 1, 24 do
        processes[index] = {pid = "{node|0x" .. tostring(index) .. "}", source = "bee.demo:p" .. tostring(index),
            host = hosts[index % 3 + 1], state = states[index % 4 + 1], steps = index * 37 + step}
    end
    local services: {probe.Service} = {}
    for index = 1, 30 do
        services[index] = {id = "bee.demo:s" .. tostring(index), state = index == 7 and "failed" or (index == 9 and "starting" or "running"),
            desired = "running", restarts = index == 7 and 3 or 0}
    end
    return {processes = processes, services = services, heap = (12 + step % 5) * 1048576, heap_objects = 120000,
        reserved = 48 * 1048576, gc_cycles = 38, goroutines = 214, queue = step % 3, executed = step * 900,
        host_executed = {main = step * 900}, error = ""}
end
local function history(): probe.History
    local value = probe.new_history()
    local previous: probe.Snapshot? = nil
    for step = 1, 60 do
        local current = sample(step)
        probe.append(value, current, previous, 1)
        previous = current
    end
    return value
end
local function plain(rows: {string}): string
    local out: {string} = {}
    for index, row in ipairs(rows) do out[index] = (row:gsub("\27%[[0-9;]*m", "")) end
    return table.concat(out, "\n")
end
local function rgb(hex: string): string
    return tostring(tonumber(hex:sub(2, 3), 16)) .. ";" .. tostring(tonumber(hex:sub(4, 5), 16)) .. ";" .. tostring(tonumber(hex:sub(6, 7), 16))
end
-- The foreground and background in effect where needle starts in a styled row.
local function style_at(row: string, needle: string): string
    local fg, bg = "", ""
    local position = 1
    while position <= #row do
        local first, last, codes = row:find("\27%[([0-9;]*)m", position)
        local plain_end = first and first - 1 or #row
        if row:sub(position, plain_end):find(needle, 1, true) then return fg .. "/" .. bg end
        if not first or not last or not codes then return "" end
        if codes == "" or codes == "0" then fg, bg = "", "" end
        local fg_code = codes:match("38;2;(%d+;%d+;%d+)")
        local bg_code = codes:match("48;2;(%d+;%d+;%d+)")
        if fg_code then fg = fg_code end
        if bg_code then bg = bg_code end
        position = last + 1
    end
    return ""
end
local function has(screen: string, needle: string): boolean
    return screen:find(needle, 1, true) ~= nil
end

local function define_tests()
    test.describe("System Monitor", function()
        test.it("keeps every frame and target inside the canvas at every size", function()
            local series = history()
            local snapshot = sample(60)
            for _, width in ipairs({1, 20, 40, 79, 80, 119, 120, 159, 160, 200}) do
                for _, height in ipairs({1, 2, 5, 6, 12, 23, 24, 35, 36, 48, 60}) do
                    local drawn = view.draw(width, height, appearance.defaults(), snapshot, series, false)
                    test.eq(#drawn.rows, height)
                    for _, row in ipairs(drawn.rows) do test.eq(tty.text.width(row), width) end
                    for _, hit in ipairs(drawn.hits) do
                        test.is_true(hit.x >= 1 and hit.y >= 1 and hit.x + hit.width - 1 <= width and hit.y + hit.height - 1 <= height)
                    end
                end
            end
        end)
        test.it("adds panels at 80x24, 120x36 and 160x48", function()
            local series = history()
            local snapshot = sample(60)
            local compact = plain(view.draw(80, 24, appearance.defaults(), snapshot, series, false).rows)
            for _, needle in ipairs({"SYSTEM MONITOR", "Live · 1s · 24 processes", "HEAP", "12.0 MiB", "SCHEDULER", "900 steps/s",
                "PROCESSES BY STATE", "idle", "SERVICES", "28 running · 1 failed · 1 starting", "on 3 hosts", "16 MiB ┤", "-60s",
                "Enter Refresh", "P Pause", "Enter refresh · P pause · Esc close"}) do
                test.eq(needle .. (has(compact, needle) and "" or " missing"), needle)
            end
            test.is_false(has(compact, "HOSTS"))
            local standard = plain(view.draw(120, 36, appearance.defaults(), snapshot, series, false).rows)
            for _, needle in ipairs({"HOSTS", "bee:terminal", "█ idle  ▓ running  ▒ waiting", "MEMORY", "48.0 MiB reserved", "25%",
                "120k objects · 38 GC cycles"}) do
                test.eq(needle .. (has(standard, needle) and "" or " missing"), needle)
            end
            test.is_false(has(standard, "TOPOLOGY"))
            local wide = plain(view.draw(160, 48, appearance.defaults(), snapshot, series, false).rows)
            for _, needle in ipairs({"TOPOLOGY", "● node", "▸● bee:workers", "8 processes", "STEPS PER PROCESS", "948"}) do
                test.eq(needle .. (has(wide, needle) and "" or " missing"), needle)
            end
            local narrow = plain(view.draw(60, 16, appearance.defaults(), snapshot, series, false).rows)
            test.is_true(has(narrow, "Heap 12.0 MiB · 900 steps/s"))
            test.is_true(has(narrow, "30 services · 3 hosts"))
            test.is_false(has(narrow, "PROCESSES BY STATE"))
        end)
        test.it("marks the paused state in words and on the active toggle", function()
            local theme = appearance.theme("honey")
            local drawn = view.draw(80, 24, appearance.defaults(), sample(60), history(), true)
            local screen = plain(drawn.rows)
            test.is_true(has(screen, "Paused · 24 processes"))
            test.is_true(has(screen, "P Resume"))
            local kinds: {string} = {}
            for _, hit in ipairs(drawn.hits) do kinds[#kinds + 1] = hit.kind end
            test.eq(table.concat(kinds, ","), "refresh,pause")
            test.eq(style_at(drawn.rows[23], "P Resume"), rgb(appearance.selection_text(theme)) .. "/" .. rgb(theme.accent))
            test.eq(style_at(drawn.rows[23], "Enter Refresh"), rgb(appearance.selection_text(theme)) .. "/" .. rgb(theme.accent))
        end)
        test.it("keeps a failed source inside its panel and reports it in the footer", function()
            local broken = sample(60)
            broken.heap = nil
            broken.reserved = nil
            broken.services = {}
            broken.error = "memory.stats: denied"
            local screen = plain(view.draw(120, 36, appearance.defaults(), broken, history(), false).rows)
            test.is_true(has(screen, "Heap unavailable"))
            test.is_true(has(screen, "No services reported"))
            test.is_true(has(screen, "Memory statistics unavailable"))
            test.is_true(has(screen, "PROCESSES BY STATE"))
            test.is_true(has(screen, "memory.stats: denied"))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
