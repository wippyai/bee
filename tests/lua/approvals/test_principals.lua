-- MIT. Shared Approvals fixture identities and caller scopes.
local uuid = require("uuid")
local security = require("security")
local funcs = require("funcs")
local M = {}
function M.key(): string
    local id, err = uuid.v4()
    if err or not id then error("uuid: " .. tostring(err)) end
    return id
end
function M.scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
function M.caller(id: string, grants: {string}, metadata: {[string]: string | integer}?): funcs.Executor
    local names: {string} = {"bee.approvals:client_test_policy"}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    return funcs.new():with_actor(security.new_actor(id, metadata)):with_scope(M.scope(names))
end
return M
