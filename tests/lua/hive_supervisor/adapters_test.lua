-- MIT. Host-selected forwarded-operation adapter table decoder tests.
local test = require("test")
local adapters = require("adapters")

local function rejected(value: unknown)
    local decoded, err = adapters.decode(value)
    test.is_nil(decoded)
    test.not_nil(err)
end

local function define_tests()
    test.describe("Hive operation adapters", function()
        test.it("decodes dense routes and rejects malformed or duplicate rows", function()
            local decoded, err = adapters.decode({adapters = {{operations = {"bee.threads.service:send"}, worker = "bee.threads.hive:admit"}}})
            test.is_nil(err)
            if not decoded then error("valid adapter table was rejected") end
            test.eq(adapters.worker_of(decoded, "bee.threads.service:send"), "bee.threads.hive:admit")

            rejected({adapters = {thread = {operations = {"bee.threads.service:send"}, worker = "bee.threads.hive:admit"}}})
            rejected({adapters = {[1] = {operations = {"bee.threads.service:send"}, worker = "bee.threads.hive:admit"},
                [3] = {operations = {"bee.sync.binding:replica_receive"}, worker = "bee.sync.hive:admit"}}})
            rejected({adapters = {
                {operations = {"bee.threads.service:send"}, worker = "bee.threads.hive:admit"},
                {operations = {"bee.threads.service:send"}, worker = "bee.sync.hive:admit"},
            }})
        end)
    end)
end

return test.run_cases(define_tests)
