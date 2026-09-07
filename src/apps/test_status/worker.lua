-- MIT. Real shared-UI checks with durable results. No terminal or view lifetime.
local journal = require("journal")
local appearance = require("appearance")
local tty = require("tty")
local time = require("time")
local channel = require("channel")
local process = require("process")
local json = require("json")
local function main(thread: string, run: string)
    local log, open_error = journal.open(thread)
    if not log then error(open_error or "Journal unavailable") end
    local function emit(key: string, kind: string, body: string)
        local receipt, err = log:append(run, key, kind, body)
        if not receipt then error(err or "Event commit failed") end
    end
    emit("started", "test.run.started", '{"suite":"Shared UI","total":6}')
    local cases: {{name: string, check: () -> boolean}} = {
        {name = "ASCII cell width", check = function(): boolean return tty.text.width("Bee") == 3 end},
        {name = "Wide Unicode cells", check = function(): boolean return tty.text.width("界") == 2 end},
        {name = "Combining characters", check = function(): boolean return tty.text.width("é") == 1 end},
        {name = "Truncation stays in bounds", check = function(): boolean return tty.text.width(tty.text.truncate("日本語", 5, "…")) <= 5 end},
        {name = "Theme colors are valid RGB", check = function(): boolean
            for _, theme in ipairs(appearance.themes()) do
                for _, color in ipairs({theme.text, theme.ground, theme.surface, theme.accent, appearance.selection_text(theme)}) do
                    if #color ~= 7 or color:sub(1, 1) ~= "#" or not tonumber(color:sub(2), 16) then return false end
                end
            end
            return true
        end},
        {name = "Wallpapers fill their width", check = function(): boolean
            for _, name in ipairs(appearance.backgrounds()) do
                for y = 1, 5 do
                    local row = tty.text.truncate(appearance.background_row(name, 31, y, 5), 31, "")
                    if tty.text.width(row) ~= 31 then return false end
                end
            end
            return true
        end},
    }
    local events = assert(process.events())
    local passed, failed = 0, 0
    for index, item in ipairs(cases) do
        local delay = assert(time.timer("300ms"))
        local selected = channel.select({delay:channel():case_receive(), events:case_receive()})
        delay:stop()
        if not selected.ok or selected.channel == events then
            emit("interrupted", "test.run.interrupted", "{}")
            return
        end
        local ok, result = pcall(item.check)
        local success = ok and result == true
        if success then passed = passed + 1 else failed = failed + 1 end
        local body, body_error = json.encode({name = item.name, passed = success})
        if not body then error(tostring(body_error)) end
        emit("case-" .. tostring(index), success and "test.case.passed" or "test.case.failed", body)
    end
    local body, body_error = json.encode({passed = passed, failed = failed})
    if not body then error(tostring(body_error)) end
    emit("finished", "test.run.finished", body)
end
return {main = main}
