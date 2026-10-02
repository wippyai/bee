-- SPDX-License-Identifier: MIT
local registry = require("registry")
local funcs = require("funcs")
local fs = require("fs")
local json = require("json")
local process = require("process")
local channel = require("channel")
local time = require("time")
local bounds = require("bounds")
local environment = require("environment")
local resources = require("resources")
local image = require("image")
local docker_client = require("docker_client")
local hash = require("hash")
local canonical = require("canonical")
local events = require("events")
local system = require("system")
local M = {}
type Channel = channel.Channel
type Object = {[string]: unknown}
local function approval_call(method: string, request: Object): (Object?, string?)
    local reply, call_error = funcs.call("bee.approvals.binding:" .. method, request)
    local value = bounds.object(reply)
    local fault = value and bounds.object(value.error)
    if call_error or not value or value.ok ~= true then return nil, tostring(call_error or fault and fault.message or "approval owner did not answer") end
    return bounds.object(value.value), nil
end
local function configuration(): (Object?, string?)
    local entry = registry.get("bee.placement.docker.env:environment_configuration")
    local record = entry and bounds.object(entry.data)
    local data = record and bounds.object(record.value)
    if not data or bounds.fields(data, {"network", "endpoint", "listener", "readiness_policy", "approval_policy"})
        or not bounds.id(data.network) or not bounds.id(data.endpoint) or not bounds.id(data.listener) or not bounds.id(data.readiness_policy) or not bounds.id(data.approval_policy) then
        return nil, "the host selects no Docker network and gateway provisioning policy"
    end
    return data, nil
end
local function receipt(value: unknown): environment.Receipt?
    local data = bounds.object(value)
    if not data or bounds.fields(data, {"state", "selection_digest", "approval_id", "proposal_digest", "owner_incarnation", "address"}) then return nil end
    local state = bounds.member(data.state, {"pending", "approved", "denied", "revoked"})
    local digest, id, proposal = bounds.line(data.selection_digest,64), bounds.id(data.approval_id), bounds.line(data.proposal_digest,64)
    local incarnation = bounds.count(data.owner_incarnation)
    local address = data.address == nil and nil or bounds.line(data.address,128)
    if not state then return nil end
    if not digest or #digest ~= 64 then return nil end
    if not id then return nil end
    if not proposal or #proposal ~= 64 then return nil end
    if not incarnation or incarnation < 1 then return nil end
    if data.address ~= nil and not address then return nil end
    if state == "approved" and not address then return nil end
    local result: environment.Receipt = {state = state, selection_digest = digest, approval_id = id, proposal_digest = proposal, owner_incarnation = incarnation, address = address}
    return result
end
function M.run(profile_ref: string, digest: string, network: string, workspace: string, recipient: string?, cancel: Channel<boolean>?, revoke: boolean?): (string?, string?)
    local config, config_error = configuration()
    if not config then return nil, config_error end
    if network ~= config.network then return nil, "Docker profile network is outside the host-selected provisioning policy" end
    local selected_json, encode_error = canonical.encode({profile_digest = digest, configuration = config},4096,8)
    local selected_digest = selected_json and hash.sha256(selected_json)
    if not selected_digest then return nil, encode_error or "Docker environment selection could not be measured" end
    digest = selected_digest
    local root = resources.root()
    local volume = root and fs.get(root)
    if not volume then return nil, "Docker environment receipt root unavailable" end
    local path = "/images/environment.json"
    local function load(): (environment.Receipt?, string?)
        local found = volume:stat(path)
        if not found then return nil, nil end
        local content = volume:readfile(path)
        if not content or #content > 4096 then return nil, "Docker environment receipt is unreadable" end
        local decoded = json.decode(content)
        local recorded = receipt(decoded)
        if not recorded then return nil, "Docker environment receipt is malformed" end
        return recorded, nil
    end
    local function save(value: environment.Receipt): string?
        local encoded = json.encode(value)
        local written, write_error = encoded and volume:writefile(path, encoded, {atomic = true})
        if not written then return tostring(write_error or "record Docker environment") end
        return nil
    end
    local function listener_action(kind: string, expected: string): string?
        local sent, send_error = events.send("supervisor", "service." .. kind, tostring(config.listener))
        if not sent then return tostring(send_error or "gateway listener lifecycle request refused") end
        local deadline = time.after("15s")
        while true do
            local current, read_error = system.supervisor.state(tostring(config.listener))
            if read_error or not current then return tostring(read_error or "gateway listener state unavailable") end
            if current.status == expected then return nil end
            local selected = channel.select({time.after("50ms"):case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then return "gateway listener did not become " .. expected end
        end
    end
    if revoke then
        local recorded, read_error = load()
        if not recorded then return nil, read_error or "Docker environment has no admission to revoke" end
        local revoked_receipt: environment.Receipt = {state = "revoked", selection_digest = recorded.selection_digest, approval_id = recorded.approval_id, proposal_digest = recorded.proposal_digest, owner_incarnation = recorded.owner_incarnation, address = recorded.address}
        local saved = save(revoked_receipt)
        if saved then return nil, saved end
        local overlay = registry.overlay("bee.placement.docker.env:environment")
        if not overlay then return nil, "Docker environment overlay unavailable" end
        local stopped = listener_action("stop", "stopped")
        if stopped then return nil, stopped end
        local changes = overlay:changes()
        changes:delete(tostring(config.endpoint)); changes:delete(tostring(config.listener)); changes:delete(tostring(config.readiness_policy))
        local _, apply_error = changes:apply()
        if apply_error then return nil, tostring(apply_error) end
        local started = listener_action("start", "running")
        return started == nil and "revoked" or nil, started
    end
    local io: environment.IO = {
        load = load, save = save,
        progress = function(text)
            if recipient then process.send(recipient, image.TOPIC, {version = 1, detail = text, profile_ref = profile_ref}) end
        end,
        request = function(selected: environment.Selection): (environment.Approval?, string?)
            local filed, error = approval_call("request", {workspace_id = selected.workspace, idempotency_key = "docker-environment:" .. selected.digest,
                request_kind = "permission", policy = selected.policy,
                proposal = {kind = "operation", ref = "bee.placement.docker.binding:prepare_environment", revision = selected.digest,
                    input_digest = selected.digest, payload = {network = selected.network, endpoint = config.endpoint, listener = config.listener, profile = selected.profile}},
                prompt = {text = "Allow Bee to create the " .. selected.network .. " Docker network and bind the restricted agent gateway to its host bridge? This recorded admission can be revoked from the Agent window."}})
            local decoded = filed and receipt({state = "pending", selection_digest = selected.digest, approval_id = filed.approval_id,
                proposal_digest = filed.proposal_digest, owner_incarnation = filed.owner_incarnation})
            if not decoded then return nil, error or "approval owner returned an invalid Docker environment approval" end
            local chosen: environment.Approval = {approval_id = decoded.approval_id, proposal_digest = decoded.proposal_digest, owner_incarnation = decoded.owner_incarnation}
            return chosen, nil
        end,
        await = function(approval: environment.Approval): (string?, string?)
            local deadline = time.after("10m")
            while true do
                local current, error = approval_call("read", {approval_id = approval.approval_id})
                if not current then return nil, error end
                if current.proposal_digest ~= approval.proposal_digest then return nil, "Docker environment approval changed" end
                if current.state ~= "pending" then return bounds.line(current.decision,32) or tostring(current.state), nil end
                local cases = {time.after("250ms"):case_receive(), deadline:case_receive()}
                if cancel then cases[#cases + 1] = cancel:case_receive() end
                local next_event = channel.select(cases)
                if not next_event.ok or next_event.channel == cancel or next_event.channel == deadline then return nil, "Docker environment approval remains pending; no launch occurred" end
            end
        end,
        consume = function(approval: environment.Approval): string?
            local consumed, error = approval_call("consume", {approval_id = approval.approval_id, proposal_digest = approval.proposal_digest,
                owner_incarnation = approval.owner_incarnation, effect_key = "docker-environment:" .. digest})
            if not consumed then return error or "Docker environment approval is not consumable" end
            return nil
        end,
        provision = function(selected: environment.Selection): (string?, string?)
            local client = docker_client.new("/var/run/docker.sock")
            if not client then return nil, "Docker daemon unavailable" end
            local net = client:inspect_network(selected.network)
            if not net then
                local created, error = image.command({"docker", "network", "create", "--driver", "bridge", "--label", "bee.owner=bee.placement.docker", selected.network}, nil, cancel)
                if not created then return nil, error end
                net = client:inspect_network(selected.network)
            end
            local object = bounds.object(net)
            local labels = object and bounds.object(object.Labels)
            local ipam = object and bounds.object(object.IPAM)
            local configs = ipam and bounds.array(ipam.Config,8)
            local first = configs and bounds.object(configs[1])
            local gateway = first and bounds.line(first.Gateway,64)
            if not object or object.Driver ~= "bridge" or not labels or labels["bee.owner"] ~= "bee.placement.docker"
                or not gateway or not (gateway:match("^172%.") or gateway:match("^10%.") or gateway:match("^192%.168%.")) then
                return nil, "Docker network is not an owned private bridge; no gateway bridge_host admitted"
            end
            return gateway .. ":0", nil
        end,
        activate = function(recorded: environment.Receipt): string?
            if not recorded.address then return "Docker environment has no gateway address" end
            local overlay, error = registry.overlay("bee.placement.docker.env:environment")
            if not overlay then return tostring(error) end
            local active = registry.get(tostring(config.endpoint))
            local active_data = active and bounds.object(active.data)
            local active_listener = registry.get(tostring(config.listener))
            local listener_data = active_listener and bounds.object(active_listener.data)
            if not active_data or active_data.address ~= recorded.address or not listener_data or listener_data.addr ~= recorded.address then
                local endpoint = registry.get(tostring(config.endpoint))
                local listener = registry.get(tostring(config.listener))
                if not endpoint or not listener then return "host-selected gateway entries unavailable" end
                local stopped = listener_action("stop", "stopped")
                if stopped then return stopped end
                local changes = overlay:changes()
                changes:update({id = tostring(config.endpoint), kind = "registry.entry", meta = endpoint.meta, data = {address = recorded.address}})
                changes:update({id = tostring(config.listener), kind = "http.service", data = {addr = recorded.address, lifecycle = {auto_start = true}}})
                local bridge_host = recorded.address:match("^([^:]+):")
                if not bridge_host then return "Docker gateway address is malformed" end
                changes:update({id = tostring(config.readiness_policy), kind = "security.policy.expr", data = {policy = {
                    actions = {"http_client.request", "http_client.private_ip"}, resources = "*", effect = "allow",
                    expression = '(action == "http_client.private_ip" && resource == "' .. bridge_host .. '") || (action == "http_client.request" && resource matches "^http://' .. bridge_host:gsub("%.", "[.]") .. ':[0-9]+/ready$")'}}})
                local _, apply_error = changes:apply()
                if apply_error then return tostring(apply_error) end
                local started = listener_action("start", "running")
                if started then return started end
            end
            local deadline = time.after("15s")
            while true do
                local address = funcs.call("bee.gateway.binding:address", {})
                local chosen = bounds.object(address)
                if chosen and type(chosen.address) == "string" and chosen.address:match("^([^:]+):") == recorded.address:match("^([^:]+):") then return nil end
                local selected = channel.select({time.after("50ms"):case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then return "approved Docker gateway listener has not become ready" end
            end
        end,
    }
    local selected: environment.Selection = {workspace = workspace, profile = profile_ref, digest = digest, network = network, policy = tostring(config.approval_policy)}
    local recorded, error = environment.prepare(io, selected)
    return recorded and recorded.address or nil, error
end
function M.recorded(): boolean
    local root = resources.root()
    local volume = root and fs.get(root)
    return volume ~= nil and volume:stat("/images/environment.json") ~= nil
end
function M.revoked(): boolean
    local root = resources.root()
    local volume = root and fs.get(root)
    local raw = volume and volume:readfile("/images/environment.json")
    local value = raw and json.decode(raw)
    local recorded = receipt(value)
    return recorded ~= nil and recorded.state == "revoked"
end
return M
