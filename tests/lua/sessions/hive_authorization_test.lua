-- MIT
local test = require("test")
local security = require("security")
local bounds = require("bounds")
local funcs = require("funcs")
local registry = require("registry")
local WORKSPACE = string.rep("a", 32)
local APP = "bee.harness.app:app"
local function request(operation: string, arguments: {[string]: unknown}?): {[string]: unknown}
    return {application = APP, workspace_id = WORKSPACE, service = "sessions", operation = operation,
        arguments = arguments or {}, idempotency_key = "test-key"}
end
local function consent(scope: string, duration: integer?): {[string]: unknown}
    local raw, err = funcs.call("bee.threads.sessions.binding:allowance", {operation = "grant", peer = "peer-a",
        workspace_id = WORKSPACE, scope = scope, duration_ms = duration})
    assert(not err, tostring(err))
    return assert(bounds.object(raw))
end
local function revoke()
    assert(funcs.call("bee.threads.sessions.binding:allowance", {operation = "revoke", peer = "peer-a", workspace_id = WORKSPACE}))
end
local function authorized(asked: {[string]: unknown}, caller: string, node: string): (unknown?, string?)
    local raw, err = funcs.new():with_actor(assert(security.new_actor("bee.hive.supervisor"))):call("bee.tests.sessions:hive_authorize_probe",
        {request = asked, caller = caller, node = node})
    assert(not err, tostring(err))
    local reply = assert(bounds.object(raw))
    return reply.ok == true and {} or nil, type(reply.error) == "string" and reply.error or nil
end
local function define_tests()
    test.describe("Hive Sessions authorization", function()
        test.it("refuses peers without destination allowance", function()
            local invocation, err = authorized(request("list"), "{peer-a@workers|1}", "receiver")
            test.is_nil(invocation)
            test.contains(tostring(err), "allowance")
        end)
        test.it("records one Needs you request and gives agents no consent management authority", function()
            local asked = request("list")
            authorized(asked, "{peer-request@workers|1}", "receiver")
            authorized(asked, "{peer-request@workers|2}", "receiver")
            local rows = assert(registry.find({["meta.type"] = "bee.sessions.allowance"}))
            local found = 0
            for _, entry in ipairs(rows) do
                if entry.data.peer == "peer-request" then
                    found = found + 1
                    test.not_nil(entry.data.approval_id)
                    test.eq(entry.data.scope, nil)
                end
            end
            test.eq(found, 1)
            local policy = assert(security.policy("bee.threads.sessions.security:person_allowance_policy"))
            local actor = assert(security.new_actor("bee.hive.member.peer-request", {workspace_id = WORKSPACE, node = "peer-request"}))
            test.is_true(policy:evaluate(actor, "bee.sessions.allowance.manage", WORKSPACE) ~= "allow")
        end)
        test.it("limits list-only allowance and rejects forged peer fields", function()
            test.eq(consent("list").ok, true)
            local exposure = assert(registry.find({[".kind"] = "security.policy.expr"}))
            for _, entry in ipairs(exposure) do
                if entry.id:find("bee.security.hive:session_", 1, true) then
                    local data = assert(bounds.object(entry.data))
                    local policy = assert(bounds.object(data.policy))
                    local expression = assert(bounds.text(policy.expression))
                    assert(expression:find("bee.threads.sessions.binding:list", 1, true), expression)
                end
            end
            test.not_nil(authorized(request("list"), "{peer-a@workers|1}", "receiver"))
            test.is_nil(authorized(request("send", {session = "bs:receiver:" .. WORKSPACE .. ":s", input = "hi", operation_key = "k"}), "{peer-a@workers|1}", "receiver"))
            local forged = request("list")
            forged.peer = "peer-a"
            test.is_nil(authorized(forged, "{peer-b@workers|1}", "receiver"))
            test.is_nil(authorized(request("list", {peer = "peer-a"}), "{peer-b@workers|1}", "receiver"))
            revoke()
        end)
        test.it("permits message and await without launch or control", function()
            test.eq(consent("message").ok, true)
            test.not_nil(authorized(request("send", {session = "bs:receiver:" .. WORKSPACE .. ":s", input = "hi", operation_key = "k"}), "{peer-a@workers|1}", "receiver"))
            test.not_nil(authorized(request("await", {subject = "bw:receiver:" .. WORKSPACE .. ":w", timeout_ms = 0}), "{peer-a@workers|1}", "receiver"))
            test.is_nil(authorized(request("open", {spec = {definition = "d"}, operation_key = "k"}), "{peer-a@workers|1}", "receiver"))
            test.is_nil(authorized(request("close", {session = "bs:receiver:" .. WORKSPACE .. ":s", operation_key = "k"}), "{peer-a@workers|1}", "receiver"))
            revoke()
        end)
        test.it("rechecks revocation, workspace bounds and expiry", function()
            test.eq(consent("open").ok, true)
            local args = {spec = {definition = "d"}, operation_key = "k"}
            test.not_nil(authorized(request("open", args), "{peer-a@workers|1}", "receiver"))
            test.is_nil(authorized(request("get", {session = "bs:receiver:" .. string.rep("b", 32) .. ":s"}), "{peer-a@workers|1}", "receiver"))
            revoke()
            test.is_nil(authorized(request("list"), "{peer-a@workers|1}", "receiver"))
            test.eq(consent("list", 1).ok, true)
            local entries = assert(registry.find({["meta.type"] = "bee.sessions.allowance"}))
            for _, entry in ipairs(entries) do
                if entry.data.peer == "peer-a" then
                    entry.data.expires_ms = 1
                    local changes = registry.snapshot():changes()
                    changes:update({id = tostring(entry.id), kind = tostring(entry.kind), meta = bounds.object(entry.meta), data = entry.data})
                    assert(changes:apply())
                end
            end
            test.is_nil(authorized(request("list"), "{peer-a@workers|1}", "receiver"))
            revoke()
        end)
    end)
end
return test.run_cases(define_tests)
