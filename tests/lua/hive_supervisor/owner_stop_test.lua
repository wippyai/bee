-- MIT. An enrolled local client asks its own owner to shut down. The request
-- names this node's owner service and one operation; a client that asks only
-- when it is alone leaves an owner another local client uses running.
local test = require("test")
local types = require("types")
local owner_stop = require("owner_stop")
type Object = {[string]: unknown}
local NODE = "owner-node"

local function call(input: Object, operation: string?, owner: types.OwnerRef?): types.Call
    return {protocol_revision = types.REVISION, request_id = "request-1", idempotency_key = "key-1",
        owner_ref = owner or {node_id = NODE, service_id = owner_stop.SERVICE},
        target = {operation_ref = operation or owner_stop.STOP}, input = input}
end

local function define_tests()
    test.describe("owner stop", function()
        test.it("decodes a stop of this node's owner and nothing else", function()
            local request = assert(owner_stop.decode(call({alone = true}), NODE))
            test.is_true(request.alone)
            test.is_false(assert(owner_stop.decode(call({alone = false}), NODE)).alone)
            local _, foreign = owner_stop.decode(call({alone = false}, nil, {node_id = "other-node", service_id = owner_stop.SERVICE}), NODE)
            test.eq(foreign and foreign.code, "DENIED")
            local _, unknown = owner_stop.decode(call({alone = false}, "bee.hive.owner:restart"), NODE)
            test.eq(unknown and unknown.code, "INVALID_ARGUMENT")
            local _, extra = owner_stop.decode(call({alone = false, force = true}), NODE)
            test.eq(extra and extra.code, "INVALID_ARGUMENT")
            local _, missing = owner_stop.decode(call({}), NODE)
            test.eq(missing and missing.code, "INVALID_ARGUMENT")
        end)
        test.it("stops when asked unconditionally or when the caller is the only local client", function()
            test.is_true(owner_stop.stops({alone = false}, "client-a", {["client-a"] = true, ["client-b"] = true}))
            test.is_true(owner_stop.stops({alone = true}, "client-a", {["client-a"] = true}))
            test.is_false(owner_stop.stops({alone = true}, "client-a", {["client-a"] = true, ["client-b"] = true}))
        end)
        test.it("accepts the forwarded stop only from this node's supervisor", function()
            test.is_true(owner_stop.from_supervisor("{node@bee.hive:supervisor_host|0x1}", "{node@bee.hive:supervisor_host|0x1}"))
            test.is_false(owner_stop.from_supervisor("{node@bee:workers|0x2}", "{node@bee.hive:supervisor_host|0x1}"))
            test.is_false(owner_stop.from_supervisor("{node@bee.hive:supervisor_host|0x1}", nil))
        end)
    end)
end

return test.run_cases(define_tests)
