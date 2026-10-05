-- MIT. Terminal: a native local shell in the desktop's workspace folder. The
-- node supplies its sole terminal producer capability and the workspace; the
-- shell's PTY renders in this app's terminal port.
local tty = require("tty")
local exec = require("exec")
local process = require("process")
local channel = require("channel")
local command = require("command")

type Options = {args: {[string]: unknown}?, workspace: {path: string}?}

-- arguments are the command an app open asks for, as words.
local function arguments(options: Options): {string}
    local words: {string} = {}
    local args = options.args
    if args and type(args.arguments) == "table" then
        for _, word in ipairs(args.arguments) do
            if type(word) == "string" then words[#words + 1] = word end
        end
    end
    return words
end

local function main(value: unknown)
    local options: Options = {args = nil, workspace = nil}
    if type(value) == "table" then options = value :: Options end
    local input = assert(tty.events())
    local events = assert(process.events())
    assert(tty.start())
    local executor = assert(exec.get("bee.apps.terminal:executor"))
    local work_dir: string? = nil
    if options.workspace and type(options.workspace.path) == "string" then work_dir = options.workspace.path end
    -- The PTY takes the current terminal geometry; the returned process owns the child.
    local terminal, start_error = executor:terminal(command.encode(arguments(options)),
        {pty = {term = "xterm-256color"}, work_dir = work_dir})
    if not terminal then executor:release(); error(tostring(start_error)) end
    local done = terminal:done()
    while true do
        local selected = channel.select({input:case_receive(), events:case_receive(), done:case_receive()})
        if not selected.ok or selected.channel == done then break end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
        elseif selected.channel == input then
            local event = selected.value
            if event.type == "close" then break end
            if event.type ~= "start" then
                local sent = terminal:send(event)
                if not sent then break end
            end
        end
    end
    -- The application owns its shell: it returns only after the child is reaped.
    terminal:close()
    done:receive()
    executor:release()
    tty.stop()
end
return {main = main}
