-- MIT. The lease grant flow over a fake Approvals owner: the terms an approver
-- reads, a retry that replays, a restart that asks for revalidation, and
-- extras resolved through the host catalog.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local registry = require("registry")
local uuid = require("uuid")
local capability_model = require("capability_model")
local lease_grants = require("lease_grants")
local lease_store = require("lease_store")

type Object = {[string]: unknown}
local PROFILE = {overlay_owner = "bee.gov:lease-grants", approval_policy = "policy-a", source_workspace = "notes"}

local function vocabulary(): capability_model.Vocabulary
    return assert(capability_model.decode(assert(registry.get("bee.capability:catalog"))))
end

-- A fake owner: request stores the proposal, the test decides it, consume may
-- demand revalidation once (an owner restart) before it accepts.
local function owner(state: Object): lease_grants.Executor
    local executor: lease_grants.Executor = {call = function(_self: lease_grants.Executor, method: string, request: unknown): (unknown?, unknown?)
        local input = assert(bounds.object(request))
        local calls = principals.strings(state.calls)
        state.calls = calls
        calls[#calls + 1] = method
        if method == "bee.approvals.binding:request" then
            state.request = input
            return {ok = true, value = {approval_id = "approval-1", proposal_digest = string.rep("a", 64), revision = 1,
                proposal = input.proposal}}, nil
        end
        if method == "bee.approvals.binding:read" then
            return {ok = true, value = {approval_id = "approval-1", state = state.decided and "decided" or "pending",
                decision = state.decided and "approved" or nil, policy = "policy-a", workspace_id = "ws",
                proposal = (assert(bounds.object(state.request))).proposal, proposal_digest = string.rep("a", 64),
                owner_incarnation = 1, decider_id = "person"}}, nil
        end
        if method == "bee.approvals.binding:revalidate" then
            state.validated = input.owner_incarnation
            return {ok = true, value = {validated_incarnation = input.owner_incarnation}}, nil
        end
        test.eq(method, "bee.approvals.binding:effect")
        test.eq(input.operation, "claim")
        if state.restarted and state.validated ~= 2 then
            return {ok = false, error = {code = "REVALIDATE", message = "restarted"}, value = {current_incarnation = 2}}, nil
        end
        state.consumed = input.owner_incarnation
        return {ok = true, value = {approval_id = "approval-1"}}, nil
    end}
    return executor
end

local function read(state: Object, name: string): unknown
    return state[name]
end

local function define_tests()
    test.describe("Lease grant flow", function()
        test.it("puts the lease terms and the whole ceiling in the approval the person reads", function()
            local state: Object = {calls = {}}
            local vocab = vocabulary()
            local installed = assert(capability_model.resolve(vocab, "workspace.files.write", {subpath = "alpha"}))
            local reply = lease_grants.propose(owner(state) , vocab, installed, PROFILE, "ws",
                {source_node = "node", source_workspace = "notes", ttl_seconds = 2592000, max_applies = 4}, "key-1")
            test.is_true(reply.ok == true)
            local payload = assert(bounds.object((assert(bounds.object((assert(bounds.object(state.request))).proposal))).payload))
            test.eq(payload.ttl_seconds, 2592000)
            test.eq(payload.max_applies, 4)
            local terms = table.concat(principals.strings(payload.permission_changes), "\n")
            test.is_true(terms:find("30 days", 1, true) ~= nil)
            test.is_true(terms:find("moment it is granted", 1, true) ~= nil)
            test.is_true(terms:find("At most 4 applies", 1, true) ~= nil)
            test.is_true(terms:find(PROFILE.overlay_owner, 1, true) ~= nil)
            test.eq(#(principals.strings(payload.resolved_capabilities)), 1)
        end)
        test.it("accepts parameterless extras and one-member sets from text", function()
            local vocab = vocabulary()
            local installed = assert(capability_model.resolve(vocab, "workspace.files.write", {subpath = "alpha"}))
            local state: Object = {calls = {}}
            local reply = lease_grants.propose(owner(state) , vocab, installed, PROFILE, "ws",
                {source_node = "node", source_workspace = "notes", max_applies = 2, extras = {
                    {capability = "hive.view", parameters = {}},
                    {capability = "contract.call", parameters = {binding = "app:binding", methods = "get"}},
                    {capability = "contract.call", parameters = {binding = "app:other", methods = "get|put"}}}}, "key-1")
            test.is_true(reply.ok == true, tostring(reply.message))
            local payload = assert(bounds.object((assert(bounds.object((assert(bounds.object(state.request))).proposal))).payload))
            test.eq(#(principals.items(payload.envelope)), 4)
        end)
        test.it("refuses a ceiling the approval screen cannot show completely", function()
            local vocab = vocabulary()
            local installed = assert(capability_model.resolve(vocab, "workspace.files.write", {subpath = "alpha"}))
            local extras: {Object} = {}
            for index = 1, 8 do extras[index] = {capability = "workspace.files.write", parameters = {subpath = "d" .. tostring(index)}} end
            local reply = lease_grants.propose(owner((assert(bounds.object({calls = {}})))) , vocab, installed, PROFILE, "ws",
                {source_node = "node", source_workspace = "notes", max_applies = 2, extras = extras}, "key-1")
            test.is_true(reply.ok == true)
            local more: {Object} = {}
            for index = 1, 8 do more[index] = {capability = "workspace.files.write", parameters = {subpath = "e" .. tostring(index)}} end
            for index = 1, 8 do more[#more + 1] = extras[index] end
            local refused = lease_grants.propose(owner((assert(bounds.object({calls = {}})))) , vocab, installed, PROFILE, "ws",
                {source_node = "node", source_workspace = "notes", max_applies = 2, extras = more}, "key-2")
            test.is_false(refused.ok == true)
        end)
        test.it("grants once from a decided approval and replays an identical retry", function()
            local vocab = vocabulary()
            local installed = assert(capability_model.resolve(vocab, "workspace.files.write", {subpath = "alpha"}))
            local state: Object = {calls = {}}
            local executor = owner(state) 
            lease_grants.propose(executor, vocab, installed, PROFILE, "ws", {source_node = "node", source_workspace = "notes", max_applies = 2}, "key-1")
            local handle = assert(lease_store.open("bee:db", "node-grants", assert(uuid.v7())))
            local early = lease_grants.grant(executor, handle, vocab, PROFILE, "ws", "actor", {approval_id = "approval-1"}, "grant-1")
            test.eq(early.code, "DENIED")
            state.decided = true
            local first = lease_grants.grant(executor, handle, vocab, PROFILE, "ws", "actor", {approval_id = "approval-1"}, "grant-1")
            test.is_true(first.ok == true, tostring(first.message))
            local retry = lease_grants.grant(executor, handle, vocab, PROFILE, "ws", "actor", {approval_id = "approval-1"}, "grant-1")
            test.is_true(retry.ok == true and retry.replayed == true)
            test.eq((assert(bounds.object(retry.value))).lease_id, (assert(bounds.object(first.value))).lease_id)
            local other_key = lease_grants.grant(executor, handle, vocab, PROFILE, "ws", "actor", {approval_id = "approval-1"}, "grant-2")
            test.is_true(other_key.ok == true and other_key.replayed == true)
            local consumes = 0
            for _, method in ipairs(principals.strings(state.calls)) do if method == "bee.approvals.binding:effect" then consumes = consumes + 1 end end
            test.eq(consumes, 1)
            assert(lease_store.close(handle))
        end)
        test.it("revalidates the exact proposal after an approval owner restart and consumes under the current incarnation", function()
            local vocab = vocabulary()
            local installed = assert(capability_model.resolve(vocab, "workspace.files.write", {subpath = "alpha"}))
            local state: Object = {calls = {}}
            state.decided, state.restarted = true, true
            local executor = owner(state) 
            lease_grants.propose(executor, vocab, installed, PROFILE, "ws", {source_node = "node", source_workspace = "notes", max_applies = 2}, "key-1")
            local handle = assert(lease_store.open("bee:db", "node-restart", assert(uuid.v7())))
            local granted = lease_grants.grant(executor, handle, vocab, PROFILE, "ws", "actor", {approval_id = "approval-1"}, "grant-1")
            test.is_true(granted.ok == true, tostring(granted.message))
            test.eq(read(state, "validated"), 2)
            test.eq(read(state, "consumed"), 2)
            test.eq(((assert(bounds.object(granted.value))).source_approval_owner_incarnation), 2)
            assert(lease_store.close(handle))
        end)
    end)
end
return test.run_cases(define_tests)
