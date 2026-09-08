local io = require("io")
local ioevents = require("ioevents")

local function main(): string
    local watch, err = ioevents.watch("native.fixture:files", ".")
    if not watch then error(err) end
    local events = watch:channel()
    io.write("READY\n")
    local complete = false
    while not complete do
        local event, ok = events:receive()
        if not ok then error("watch closed before change") end
        if event and event.kind == "change" and event.path == "changed.txt" then
            complete = true
        end
    end
    watch:close()
    io.write("CHANGED\n")
    return "ok"
end

local function denied(): string
    local watch, err = ioevents.watch("native.fixture:files", ".")
    if watch then
        watch:close()
        error("ungranted filesystem watch succeeded")
    end
    io.write("DENIED " .. tostring(err) .. "\n")
    return "denied"
end

return { main = main, denied = denied }
