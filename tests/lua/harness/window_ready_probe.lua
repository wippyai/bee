-- MIT. Runs the managed window runtime with a placement constructor that
-- reports when the launch reaches it and holds the launch there until the
-- test releases it, so the test controls how long durable launch work lasts.
local process = require("process")
local runtime = require("runtime")
local tty = require("tty")
local channel = require("channel")
local exec = require("exec")

return {main = function(value: unknown, observer: string, owned: boolean?)
    return runtime.main(value, {
        ["bee.placement.native.binding:binding"] = function(_attempt_id: string, _options: unknown)
            local release = assert(process.listen("bee.test.window_release", {message = true}))
            assert(process.send(observer, "bee.test.window_opening", {version = 1}))
            release:receive()
            process.unlisten(release)
            if not owned then return nil, "released by the readiness test" end
            local output = assert(tty.surface())
            assert(output:present({"Provider owns the terminal"}))
            local result_channel = channel.new(1)
            local completed: exec.TerminalResultChannel = result_channel
            local closed = false
            local window: runtime.Window = {
                send = function(_self, _event) return true, nil end,
                done = function(_self) return completed end,
                status = function(_self) return closed and "done" or "running", nil end,
                close = function(_self)
                    if not closed then result_channel:send({exit = {code = 0}}); closed = true end
                    return true, nil
                end,
                finish = function(_self) output:close(); return true, nil end,
            }
            return window, nil
        end,
    })
end}
