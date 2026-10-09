-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local demand = require("demand")
local image = require("image")
local bounds = require("bounds")
local function define_tests()
    test.describe("Docker demand dispatch", function()
        test.it("starts an absent owner and acknowledges the authenticated request", function()
            local accepted = assert(process.listen(demand.ACCEPTED, {message = true}))
            local replies = assert(process.listen(image.REPLY, {message = true}))
            local id = assert(uuid.v7())
            assert(demand.dispatch(image.OWNER, {version = 1, request_id = id}))
            local deadline = time.after("10s")
            local owner: string? = nil
            local answer: string? = nil
            local failure: string? = nil
            while not owner or not answer do
                local selected = channel.select({accepted:case_receive(), replies:case_receive(), deadline:case_receive()})
                assert(selected.channel ~= deadline, "absent Docker owner loses dispatch")
                local message = selected.value
                local value = assert(bounds.object(message:payload():data()))
                if value.request_id == id then
                    if selected.channel == accepted then
                        local supervisor = assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL))
                        test.eq(tostring(message:from()), tostring(supervisor))
                        test.eq(value.name, image.OWNER)
                        owner = assert(bounds.line(value.pid, 512))
                    else
                        answer = tostring(message:from())
                        failure = bounds.line(value.error, 512)
                    end
                end
            end
            test.eq(answer, owner)
            test.eq(failure, "image request is not recorded")
            process.unlisten(accepted)
            process.unlisten(replies)
        end)
    end)
end
return test.run_cases(define_tests)
