-- MIT. The public replica receiver derives the caller actor from the
-- authenticated execution context and authorizes the exact source owner.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local uuid = require("uuid")
local hash = require("hash")
local base64 = require("base64")
local version = require("version")

type Object = {[string]: unknown}
type Result = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean, commit: boolean?}

local function required_uuid(): string
    local value, err = uuid.v7()
    if not value then error(tostring(err)) end
    return value
end

local function required_digest(content: string): string
    local digest, err = hash.sha256(content)
    if not digest then error(tostring(err)) end
    return digest
end

local function required_base64(content: string): string
    local encoded, err = base64.encode(content)
    if not encoded then error(tostring(err)) end
    return encoded
end

local function descriptor(owner: string, content: string): version.Descriptor
    local item, err = version.create(owner, "replica-method-test", required_uuid(), "test-object", "v1",
        required_digest(content), "test-content", #content, {schema = "test-manifest@1"})
    if not item then error(tostring(err)) end
    return item
end

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end

local function caller(actor: string, source_policy: string?): funcs.Executor
    local policies = {"bee.sync:replica_method_client_policy"}
    if source_policy then policies[#policies + 1] = source_policy end
    return funcs.new():with_scope(scope(policies)):with_actor(security.new_actor(actor))
end

local function call(executor: funcs.Executor, request: Object): Result
    local reply, err = executor:call("bee.sync:replica_receive", request)
    if err then error("replica_receive: " .. tostring(err)) end
    return reply :: Result
end

local function code(reply: Result): string
    if reply.ok then error("expected replica_receive failure") end
    return reply.code or ""
end

local function define_tests()
    test.describe("Public replica receiver", function()
        test.it("requires an exact source-owner permission", function()
            local item = descriptor("node-b", "source-bound")
            local denied = call(caller("bee.test.replica.sender", "bee.sync:replica_source_node_a_policy"),
                {action = "begin", descriptor = item, source_cursor = 1})
            test.eq(code(denied), "DENIED")
        end)

        test.it("accepts a bounded begin, status, put and finish lifecycle", function()
            local content = "replica-method-content"
            local item = descriptor("node-a", content)
            local executor = caller("bee.test.replica.sender", "bee.sync:replica_source_node_a_policy")
            local begun = call(executor, {action = "begin", descriptor = item, source_cursor = 4})
            test.is_true(begun.ok)
            test.is_false(begun.replayed)
            local receiving = call(executor, {action = "status", source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.is_true(receiving.ok)
            test.eq((receiving.value :: Object).state, "receiving")
            local written = call(executor, {action = "put", source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest, offset = 0,
                content_base64 = required_base64(content)})
            test.is_true(written.ok)
            local finished = call(executor, {action = "finish", source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.is_true(finished.ok)
            test.eq((finished.value :: Object).state, "available")
            local available = call(executor, {action = "status", source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.is_true(available.ok)
            test.eq((available.value :: Object).received_bytes, #content)
            test.eq((available.value :: Object).total_bytes, #content)
        end)
    end)
end

return test.run_cases(define_tests)
