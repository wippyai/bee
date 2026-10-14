-- SPDX-License-Identifier: MIT
local tty = require("tty")
local process = require("process")
local client = require("client")
local picker = require("picker")
local recovery = require("recovery")
return {main = function(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local closes = assert(process.listen("bee.app.close", {message = true}))
    assert(tty.start())
    if launch.resume_schema ~= recovery.SCHEMA then
        tty.stop(); process.unlisten(closes)
        error("Managed window resume schema is unsupported")
    end
    local _, picker_error = picker.run(launch, input, lifecycle, closes)
    tty.stop()
    process.unlisten(closes)
    if picker_error then error(picker_error) end
end}
