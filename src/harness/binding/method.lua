-- SPDX-License-Identifier: MIT
local security = require("security")
local ctx = require("ctx")
local system = require("system")
local registry = require("registry")
local bounds = require("bounds")
local protocol = require("protocol")
local validation = require("validation")
local store = require("store")
local transaction = require("transaction")
type Result = transaction.Result
type Request = protocol.Request
local READ = "bee.harness.profiles.read"
local WRITE = "bee.harness.profiles.write"
local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end
local function authority(input: Request): (string?, string?, Result?)
    local actor_object = security.actor()
    if not actor_object then return nil, nil, failure("UNAUTHENTICATED", "profile operation requires an actor") end
    local actor = bounds.id(actor_object:id())
    if not actor then return nil, nil, failure("UNAUTHENTICATED", "profile actor identity is invalid") end
    local action = (input.operation == "get" or input.operation == "list") and READ or WRITE
    -- This check deliberately precedes registry access and database opening.
    -- Metadata is derived here from host-inherited context, never from the request.
    local workspace = bounds.id(ctx.get("bee.workspace_id"))
    if not security.can(action, input.workspace_id, {workspace_id = workspace or ""}) then
        return nil, nil, failure("DENIED", "profile operation is not authorized")
    end
    local node, node_error = system.node.id()
    if node_error or not node or node == "" then
        return nil, nil, failure("UNAVAILABLE", "native node identity is unavailable")
    end
    local owner = bounds.id(node)
    if not owner then return nil, nil, failure("UNAVAILABLE", "native node identity is invalid") end
    return owner, actor, nil
end

local function handle(raw: unknown): Result
    local input, invalid = protocol.decode(raw)
    if not input then return failure("INVALID_ARGUMENT", invalid or "invalid profile request") end
    local node, actor, denied = authority(input)
    if not node or not actor then return denied or failure("DENIED", "profile operation refused") end
    local pinned, pin_error = registry.snapshot()
    if not pinned then return failure("UNAVAILABLE", tostring(pin_error or "profile registry unavailable")) end
    if input.profile then
        local invalid_profile = validation.check(pinned, input.profile)
        if invalid_profile then return failure("INVALID_ARGUMENT", invalid_profile) end
        local ceiling_error = validation.ceiling(pinned, input.profile, bounds.ids(ctx.get("bee.agent.trait_ceiling"), true), ctx.get("bee.agent.profile_write") ~= true)
        if ceiling_error then return failure("DENIED", ceiling_error) end
    end
    return store.call(input, node, actor, pinned, validation.check)
end
return {handle = handle}
