-- MIT. The person and the agent around a delivered application, for the
-- delivery end-to-end suites: the agent authors, freezes and requests delivery;
-- the person answers in Needs you and works in the Library; the suites run the
-- activation worker's pass themselves while its service stays stopped.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local json = require("json")
local time = require("time")
local env = require("env")
local system = require("system")
local client = require("client")
local principal = require("principal")

local M = {}
type Object = {[string]: unknown}

-- A workspace on the machine home folder no display watches, so the
-- approvals a suite raises present the Inbox on no desktop.
function M.isolated(label: string): string
    local path = assert(env.get("bee.env:machine_home"))
    local added, err = client.call(assert(system.node.id()), "workspace_add", {path = path, label = label})
    if not added then error("workspace_add: " .. tostring(err)) end
    return tostring(added.workspace)
end

-- The node presents Needs you for an installation waiting for the person and
-- opens the application once it is installed, on desktops of the workspace;
-- a suite closes what it caused so later suites find the desktops as they were.
function M.running(): {[string]: boolean}
    local listed, err = client.call(assert(system.node.id()), "list", {})
    if not listed then error("list: " .. tostring(err)) end
    local ids: {[string]: boolean} = {}
    for _, raw in ipairs((listed.running or {}) :: {unknown}) do
        local instance = bounds.object(raw)
        if instance then ids[tostring(instance.id)] = true end
    end
    return ids
end

function M.close_presented(before: {[string]: boolean})
    for id in pairs(M.running()) do
        if not before[id] then
            local _, err = client.call(assert(system.node.id()), "close", {id = id, force = true})
            if err then error("close " .. id .. ": " .. tostring(err)) end
        end
    end
end

-- author is the agent that writes and delivers, scoped as the gateway's tools.
function M.author(workspace: string, name: string): funcs.Executor
    local actor = assert(security.new_actor("bee.tests." .. name .. "_author", {workspace_id = workspace}))
    local scope = security.new_scope({assert(security.policy("bee.security.gateway:gateway_tool_overlay_policy")),
        assert(security.policy("bee.security.gateway:gateway_tool_delivery_policy"))})
    return funcs.new():with_actor(actor):with_scope(scope)
end

function M.reply(raw: unknown, err: unknown): Object
    if err then error(tostring(err)) end
    return assert(bounds.object(raw))
end

function M.value(answer: Object): Object
    if answer.ok ~= true then
        local fault = bounds.object(answer.error) or {}
        error(tostring(fault.code or answer.code) .. ": " .. tostring(fault.message or answer.message))
    end
    return assert(bounds.object(answer.value))
end

-- freeze writes the pack into the agent's overlay and freezes it; the digest
-- names the frozen snapshot.
function M.freeze(writer: funcs.Executor, overlay: string, entries: {Object}, version: string): unknown
    local listed = M.value(M.reply(writer:call("bee.gov.binding:overlay_call", {operation = "list"})))
    local revision = 0
    for _, raw in ipairs((listed.overlays or {}) :: {unknown}) do
        local row = assert(bounds.object(raw))
        if row.overlay_id == overlay then revision = math.floor(tonumber(row.revision) or 0) end
    end
    if revision == 0 then
        revision = math.floor(tonumber(M.value(M.reply(writer:call("bee.gov.binding:overlay_call", {operation = "create",
            overlay_id = overlay, expected_revision = 0, idempotency_key = overlay .. "-create"}))).revision) or 0)
    end
    local put = M.value(M.reply(writer:call("bee.gov.binding:overlay_call", {operation = "put", overlay_id = overlay,
        expected_revision = revision, idempotency_key = overlay .. "-put-" .. version, path = "entries.json",
        content = assert(json.encode(entries))})))
    local frozen = M.value(M.reply(writer:call("bee.gov.binding:overlay_call", {operation = "freeze", overlay_id = overlay,
        expected_revision = put.revision, idempotency_key = overlay .. "-freeze-" .. version})))
    return frozen.digest
end

-- deliver freezes the pack and requests delivery of the frozen snapshot.
function M.deliver(writer: funcs.Executor, overlay: string, workspace: string, entries: {Object}, version: string): Object
    return M.request(writer, overlay, workspace, version, M.freeze(writer, overlay, entries, version))
end

-- request asks for delivery of a frozen snapshot again.
function M.request(writer: funcs.Executor, overlay: string, workspace: string, version: string, digest: unknown): Object
    return M.reply(writer:call("bee.gov.binding:delivery_call", {operation = "request", workspace_id = workspace,
        source_overlay_id = overlay, version = version, snapshot_digest = digest}))
end

-- answer reads what Needs you shows for the installation and decides it as the person.
function M.answer(workspace: string, approval_id: unknown, decision: string): Object
    local identity = assert(principal.value(workspace, "delivery-inbox", "bee.approvals.inbox.app:app", "1", 1))
    local person = funcs.new():with_actor(assert(security.new_actor(identity.id, identity.metadata)))
    local read = M.value(M.reply(person:call("bee.approvals.binding:read", {approval_id = approval_id})))
    M.value(M.reply(person:call("bee.approvals.binding:decide", {approval_id = approval_id,
        expected_revision = read.revision, decision = decision, proposal_digest = read.proposal_digest})))
    return read
end

function M.approve(workspace: string, approval_id: unknown): Object
    return M.answer(workspace, approval_id, "approved")
end

-- drain runs one pass of the activation worker.
function M.drain(): unknown
    local worker = funcs.new():with_actor(assert(security.new_actor("bee.gov.activation")))
    local drained, drain_error = worker:call("bee.tests.gov:activation_drain_probe", {})
    if drain_error then error(tostring(drain_error)) end
    return drained
end

-- installed runs the worker's pass and reads the delivery status until the
-- activation settles applied.
function M.installed(writer: funcs.Executor, overlay: string, workspace: string, version: string, intent_id: unknown): Object
    local drained = M.drain()
    local last: Object? = nil
    for _ = 1, 8 do
        local status = M.value(M.reply(writer:call("bee.gov.binding:delivery_call", {operation = "status",
            workspace_id = workspace, source_overlay_id = overlay, version = version, intent_id = intent_id})))
        local activation = bounds.object(status.activation)
        if activation and activation.phase == "settled" then
            if activation.outcome ~= "applied" then
                error("activation of " .. version .. " settled " .. tostring(activation.outcome) .. ": " .. tostring(json.encode(drained)))
            end
            return activation
        end
        last = activation
        time.sleep("250ms")
    end
    error("activation of " .. version .. " did not settle: " .. tostring(json.encode(last)) .. " after " .. tostring(json.encode(drained)))
end

-- settle installs a version through Needs you when it asks the person.
function M.settle(writer: funcs.Executor, overlay: string, workspace: string, delivered: Object, version: string): Object
    if delivered.approval_id ~= nil then M.approve(workspace, delivered.approval_id) end
    return M.installed(writer, overlay, workspace, version, delivered.intent_id)
end

-- restart drops the named owners' process-local overlays and runs boot
-- recovery as a restarted node does; it answers the overlays recovery refused.
function M.restart(owners: {string}): {unknown}
    local node = funcs.new():with_actor(assert(security.new_actor("bee.gov.activation")))
    local refused, restart_error = node:call("bee.tests.gov:boot_recovery_probe", {owners = owners})
    if restart_error then error(tostring(restart_error)) end
    return assert(bounds.array(refused, 64))
end

-- library acts as the person in the Library.
function M.library(workspace: string, request: Object): Object
    local identity = assert(principal.value(workspace, "delivery-library", "bee.apps.library:app", "1", 1))
    local scope = security.new_scope({assert(security.policy("bee.apps.library:destination_client")),
        assert(security.policy("bee.apps.library:delivery_operations"))})
    request.workspace_id = workspace
    return M.reply(funcs.new():with_actor(assert(security.new_actor(identity.id, identity.metadata))):with_scope(scope)
        :call("bee.gov.binding:destination_call", request))
end

return M
