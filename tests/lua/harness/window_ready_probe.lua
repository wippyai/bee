-- MIT. Runs the managed window runtime with a placement constructor that
-- reports when the launch reaches it and holds the launch there until the
-- test releases it, so the test controls how long durable launch work lasts.
local process = require("process")
local runtime = require("runtime")

return {main = function(value: unknown, observer: string)
    return runtime.main(value, {
        ["bee.placement.native.binding:binding"] = function(_attempt_id: string, _options: unknown)
            local release = assert(process.listen("bee.test.window_release", {message = true}))
            assert(process.send(observer, "bee.test.window_opening", {version = 1}))
            release:receive()
            process.unlisten(release)
            return nil, "released by the readiness test"
        end,
    })
end}
