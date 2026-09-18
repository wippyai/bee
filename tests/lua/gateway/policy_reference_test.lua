-- MIT. Characterizes the current native policy-reference semantics. A fresh
-- lookup observes an accepted policy replacement; an already-created scope
-- retains the compiled policy object it was given. The gateway resolves
-- references afresh for each tool call, so this is characterization, not a
-- binding-level policy pinning test.
local test = require("test")
local registry = require("registry")
local security = require("security")
local json = require("json")
local time = require("time")

local POLICY = "bee.gateway:policy_reference_target"
local RESOURCE = "bee.gateway_probe:policy_reference_sentinel"

type Object = {[string]: unknown}

local function entry(): Object
    local value, err = registry.get(POLICY)
    if err or not value then error("read policy reference fixture: " .. tostring(err)) end
    return value :: Object
end

local function copy(value: unknown): Object
    local encoded, encode_error = json.encode(value)
    if not encoded then error(tostring(encode_error or "encode policy entry")) end
    local decoded, decode_error = json.decode(encoded)
    if type(decoded) ~= "table" then error(tostring(decode_error or "decode policy entry")) end
    return decoded :: Object
end

local function replace(value: Object)
    local changes = registry.snapshot():changes()
    changes:update(value)
    local applied, err = changes:apply()
    if not applied then error("replace policy reference fixture: " .. tostring(err)) end
end

local function resolved(decision: string, actor: security.Actor): security.Policy
    for _ = 1, 100 do
        local policy, err = security.policy(POLICY)
        if not err and policy and policy:evaluate(actor, "funcs.call", RESOURCE) == decision then return policy end
        time.sleep("10ms")
    end
    local policy, err = security.policy(POLICY)
    if err or not policy then error("resolve policy reference fixture: " .. tostring(err)) end
    error("policy reference did not settle to " .. decision)
end

local function run()
    test.describe("Live native policy references", function()
        test.it("uses the current compiled definition on a fresh lookup", function()
            local saved = copy(entry())
            local ok, failure = pcall(function()
                local actor = security.actor()
                if not actor then error("test actor is unavailable") end
                local old_policy, old_error = security.policy(POLICY)
                if old_error or not old_policy then error("resolve original policy: " .. tostring(old_error)) end
                local old_scope = security.new_scope({old_policy})
                test.eq(old_scope:evaluate(actor, "funcs.call", RESOURCE), "undefined")

                local replacement = copy(saved)
                replacement.data = {policy = {actions = {"funcs.call"}, resources = {RESOURCE}, effect = "allow"}}
                replace(replacement)

                local current = resolved("allow", actor)
                local current_scope = security.new_scope({current})
                test.eq(current_scope:evaluate(actor, "funcs.call", RESOURCE), "allow")
                test.eq(old_scope:evaluate(actor, "funcs.call", RESOURCE), "undefined")
            end)
            local restored, restore_error = pcall(function()
                replace(saved)
                local actor = security.actor()
                if not actor then error("test actor is unavailable during restore") end
                resolved("undefined", actor)
            end)
            if not restored then error("restore policy fixture: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end
        end)
    end)
end

return test.run_cases(run)
