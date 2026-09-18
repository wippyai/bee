-- MIT. Authenticated supervisor peers may fill only their own inert replica
-- cache slot without a principal mapping.
local test = require("test")
local funcs = require("funcs")
local system = require("system")
local time = require("time")
local uuid = require("uuid")
local hash = require("hash")
local types = require("types")
local catalog = require("catalog")
local version = require("version")

local FORMAT = "2006-01-02T15:04:05.000Z07:00"
local OPERATION = "bee.sync:replica_receive"

local function request(source: string, descriptor_owner: string): types.Request
    local local_node = assert(system.node.id())
    local content = "replica-admission-" .. assert(uuid.v7())
    local content_digest = assert(hash.sha256(content))
    local descriptor = assert(version.create(descriptor_owner, "replica-admission", assert(uuid.v7()),
        "binary", "1", content_digest, "test.binary", #content,
        {schema = "test.binary@1", bytes = #content}))
    local input: {[string]: unknown} = {action = "begin", descriptor = descriptor, source_cursor = 1}
    local operation = assert(catalog.resolve(OPERATION))
    local now = time.now()
    local result: types.Request = {
        protocol_revision = types.REVISION,
        request_id = assert(uuid.v7()),
        idempotency_key = assert(uuid.v7()),
        caller_node_id = source,
        caller_incarnation = "replica-admission-incarnation",
        owner_ref = {node_id = local_node, service_id = "bee.sync"},
        operation_ref = OPERATION,
        operation_revision = operation.revision,
        input = input,
        input_digest = assert(types.digest(input)),
        principal_ref = {issuer = source, subject_id = "{" .. source .. "@bee:workers|0x00001}"},
        principal_assertion = {method = types.ASSERTION_METHOD, audience = local_node,
            issued_at = now:utc():format(FORMAT), expires_at = now:add("20s"):utc():format(FORMAT)},
        delegation_refs = {}, deadline = now:add("20s"):utc():format(FORMAT),
        causation_ref = nil, return_ref = nil,
    }
    return result
end

local function call(value: types.Request): types.Reply
    local result, err = funcs.call("bee.hive.supervisor:admit_replica", value)
    if err then error(tostring(err)) end
    return result :: types.Reply
end

local function define_tests()
    test.describe("Hive replica admission", function()
        test.it("admits an authenticated peer's own immutable replica without a PID mapping", function()
            local source = "replica-peer-" .. assert(uuid.v7())
            local reply = call(request(source, source))
            test.is_true(reply.ok)
            local result = reply.value :: {[string]: unknown}
            test.is_true(result.ok)
            test.eq(((result.value :: {[string]: unknown}).state), "receiving")
        end)

        test.it("denies source-owner substitution before replica storage", function()
            local source = "replica-peer-" .. assert(uuid.v7())
            local reply = call(request(source, "other-peer-" .. assert(uuid.v7())))
            test.is_false(reply.ok)
            test.eq((reply.error :: types.Fault).code, "DENIED")
        end)
    end)
end

return test.run_cases(define_tests)
