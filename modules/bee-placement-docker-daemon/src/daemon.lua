-- SPDX-License-Identifier: MIT
-- Optional Docker lifecycle adapter. This source is intentionally not part of
-- Bee's default pack until userspace/docker-client is published. It owns only
-- typed daemon calls; placement state and cleanup remain with Bee placement.
local registry = require("registry")
local bounds = require("bounds")
local client_module = require("docker_client")
local inspection = require("inspection")
local M = {}

M.DAEMON_REF = "bee.placement.docker.daemon:daemon_ref"

type Object = {[string]: unknown}
type Labels = {[string]: string}
type Config = Object
type Client = {
    create_container: (Client, Config, {name: string}) -> (Object?, string?),
    start_container: (Client, string) -> (boolean?, string?),
    inspect_container: (Client, string) -> (Object?, string?, integer?),
    stop_container: (Client, string, number?) -> (boolean?, string?),
    remove_container: (Client, string, boolean?) -> (boolean?, string?),
    list_containers: (Client, Object?) -> ({unknown}?, string?),
}
type Expected = {container_id: string, image_id: string, apparmor: string, started_at: string?, labels: Labels}
type CreateExpected = {image_id: string, apparmor: string, labels: Labels}
type Observation = {container_id: string, image_id: string, started_at: string?, state: string, exit_code: integer?, labels: Labels}
type FailureKind = "invalid" | "unavailable" | "absent" | "mismatch"
type Failure = {kind: FailureKind, message: string, status: integer?, container_id: string?}
type Ref = {container_id: string, expected: Expected}

local function failure(kind: FailureKind, message: string, status: integer?, container_id: string?): Failure
    return {kind = kind, message = message, status = status, container_id = container_id}
end

local function object(value: unknown, name: string): (Object?, Failure?)
    local raw = bounds.object(value)
    if not raw then return nil, failure("invalid", name .. " must be an object") end
    return raw, nil
end

local function id(value: unknown, name: string): (string?, Failure?)
    local text = bounds.text(value, 64)
    if not text or #text ~= 64 or not text:match("^[0-9a-f]+$") then
        return nil, failure("invalid", name .. " must be a full lowercase container ID")
    end
    return text, nil
end

local function labels(value: unknown, name: string): (Labels?, Failure?)
    local raw, err = object(value, name)
    if not raw then return nil, err end
    local result: Labels = {}
    local count = 0
    for key, item in pairs(raw) do
        if type(key) ~= "string" or #key == 0 or #key > 256 or key:find("%c") then
            return nil, failure("invalid", name .. " contains an invalid label name")
        end
        local text = bounds.text(item, 4096)
        if not text or text == "" or text:find("%c") then
            return nil, failure("invalid", name .. " contains an invalid label value")
        end
        count = count + 1
        if count > 32 then return nil, failure("invalid", name .. " exceeds 32 labels") end
        result[key] = text
    end
    if count == 0 then return nil, failure("invalid", name .. " must contain labels") end
    return result, nil
end

local function image(value: unknown): (string?, Failure?)
    local text = bounds.text(value, 71)
    if not text or #text ~= 71 or not text:match("^sha256:[0-9a-f]+$") then
        return nil, failure("invalid", "expected image_id must be a full sha256 ID")
    end
    return text, nil
end

local function apparmor(value: unknown): (string?, Failure?)
    local text = bounds.text(value, 128)
    if not text or not text:match("^[A-Za-z0-9_.-]+$") or text == "unconfined" then
        return nil, failure("invalid", "expected apparmor must name an enforced profile")
    end
    return text, nil
end

local function expected(value: unknown): (Expected?, Failure?)
    local raw, err = object(value, "expected")
    if not raw then return nil, err end
    local unknown = bounds.fields(raw, {"container_id", "image_id", "apparmor", "started_at", "labels"})
    if unknown then return nil, failure("invalid", "expected: " .. unknown) end
    local container_id, id_error = id(raw.container_id, "expected.container_id")
    if not container_id then return nil, id_error end
    local image_id, image_error = image(raw.image_id)
    if not image_id then return nil, image_error end
    local profile, profile_error = apparmor(raw.apparmor)
    if not profile then return nil, profile_error end
    local selected_labels, labels_error = labels(raw.labels, "expected.labels")
    if not selected_labels then return nil, labels_error end
    local started_at: string? = nil
    if raw.started_at ~= nil then
        started_at = bounds.text(raw.started_at, 64)
        if not started_at or started_at == "" or started_at:find("%c") then
            return nil, failure("invalid", "expected.started_at must be bounded text")
        end
    end
    return {container_id = container_id :: string, image_id = image_id :: string, apparmor = profile :: string,
        started_at = started_at, labels = selected_labels :: Labels}, nil
end

local function create_expected(value: unknown): (CreateExpected?, Failure?)
    local raw, err = object(value, "create.expected")
    if not raw then return nil, err end
    local unknown = bounds.fields(raw, {"image_id", "apparmor", "labels"})
    if unknown then return nil, failure("invalid", "create.expected: " .. unknown) end
    local image_id, image_error = image(raw.image_id)
    if not image_id then return nil, image_error end
    local profile, profile_error = apparmor(raw.apparmor)
    if not profile then return nil, profile_error end
    local selected_labels, labels_error = labels(raw.labels, "create.expected.labels")
    if not selected_labels then return nil, labels_error end
    return {image_id = image_id :: string, apparmor = profile :: string, labels = selected_labels :: Labels}, nil
end

local function ref(value: unknown, name: string, allow_timeout: boolean?): (Ref?, Failure?)
    local raw, err = object(value, name)
    if not raw then return nil, err end
    local unknown: string? = nil
    if allow_timeout then unknown = bounds.fields(raw, {"container_id", "expected", "timeout_seconds"})
    else unknown = bounds.fields(raw, {"container_id", "expected"}) end
    if unknown then return nil, failure("invalid", name .. ": " .. unknown) end
    local container_id, id_error = id(raw.container_id, name .. ".container_id")
    if not container_id then return nil, id_error end
    local identity, identity_error = expected(raw.expected)
    if not identity then return nil, identity_error end
    if identity.container_id ~= container_id then
        return nil, failure("invalid", name .. ".container_id differs from expected.container_id")
    end
    return {container_id = container_id :: string, expected = identity :: Expected}, nil
end

local function daemon_socket(): (string?, Failure?)
    local linked, link_error = registry.get(M.DAEMON_REF)
    if link_error or not linked then return nil, failure("unavailable", "Docker daemon binding is not configured") end
    local linked_data = linked.data
    local reference = type(linked_data) == "table" and (linked_data :: Object).resource_ref or nil
    if type(reference) ~= "string" or reference == "" then
        return nil, failure("unavailable", "Docker daemon binding is not linked")
    end
    local daemon, daemon_error = registry.get(reference)
    if daemon_error or not daemon then return nil, failure("unavailable", "Docker daemon binding is unavailable") end
    local data = daemon.data
    local socket = type(data) == "table" and (data :: Object).socket_path or nil
    if type(socket) ~= "string" or #socket < 2 or #socket > 4096 or socket:sub(1, 1) ~= "/"
        or socket:find("[%z\r\n]") then
        return nil, failure("unavailable", "Docker daemon binding has no absolute Unix socket")
    end
    return socket, nil
end

local function connect(): (Client?, Failure?)
    local socket, socket_error = daemon_socket()
    if not socket then return nil, socket_error end
    local client, connect_error = client_module.new(socket :: string)
    if not client then return nil, failure("unavailable", "Docker daemon connection failed: " .. tostring(connect_error)) end
    return client :: Client, nil
end

local function inspect_raw(client: Client, container_id: string): (Object?, Failure?)
    local value, call_error, status = client:inspect_container(container_id)
    if value then return value, nil end
    if status == 404 then return nil, failure("absent", "Docker container is absent", status) end
    return nil, failure("unavailable", "Docker inspection failed: " .. tostring(call_error), status)
end

local function decode(raw: Object, identity: Expected): (Observation?, Failure?)
    local observed, decode_error = inspection.decode(raw, identity)
    if not observed then return nil, failure("mismatch", tostring(decode_error)) end
    return observed :: Observation, nil
end

local function observe(client: Client, identity: Expected): (Observation?, Failure?)
    local raw, raw_error = inspect_raw(client, identity.container_id)
    if not raw then return nil, raw_error end
    return decode(raw, identity)
end

local function equal_labels(left: Labels, right: Labels): boolean
    local count = 0
    for key, value in pairs(left) do
        count = count + 1
        if right[key] ~= value then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    local right_count = 0
    for _ in pairs(right) do right_count = right_count + 1 end
    return count == right_count
end

local function profile_in_config(config: Config, profile: string): boolean
    local host = config.HostConfig
    if type(host) ~= "table" then return false end
    local options = (host :: Object).SecurityOpt
    if type(options) ~= "table" then return false end
    local wanted = "apparmor=" .. profile
    local found = false
    for _, option in ipairs(options :: {unknown}) do
        if type(option) == "string" and option:match("^apparmor=") then
            if option ~= wanted then return false end
            found = true
        end
    end
    return found
end

local function config_matches(config: Config, identity: CreateExpected): Failure?
    if config.Image ~= identity.image_id then return failure("mismatch", "Docker config image differs from expected image") end
    if type(config.Labels) ~= "table" then return failure("mismatch", "Docker config has no admission labels") end
    local configured = config.Labels :: Labels
    if not equal_labels(configured, identity.labels) then return failure("mismatch", "Docker config labels differ from expected labels") end
    if not profile_in_config(config, identity.apparmor) then return failure("mismatch", "Docker config AppArmor profile differs from expected profile") end
    return nil
end

function M.inspect(value: unknown): (Observation?, Failure?)
    local request, request_error = ref(value, "inspect")
    if not request then return nil, request_error end
    local client, client_error = connect()
    if not client then return nil, client_error end
    return observe(client :: Client, request.expected)
end

function M.create(value: unknown): (Observation?, Failure?)
    local raw, request_error = object(value, "create")
    if not raw then return nil, request_error end
    local unknown = bounds.fields(raw, {"name", "config", "expected"})
    if unknown then return nil, failure("invalid", "create: " .. unknown) end
    local name = bounds.text(raw.name, 128)
    if not name or not name:match("^bee%-[0-9a-f]+$") then return nil, failure("invalid", "create.name is not a deterministic Bee name") end
    local identity, identity_error = create_expected(raw.expected)
    if not identity then return nil, identity_error end
    local config = raw.config
    if type(config) ~= "table" then return nil, failure("invalid", "create.config must be a Docker config") end
    local config_error = config_matches(config :: Config, identity :: CreateExpected)
    if config_error then return nil, config_error end
    local client, client_error = connect()
    if not client then return nil, client_error end
    local created, create_error = (client :: Client):create_container(config :: Config, {name = name :: string})
    if not created then return nil, failure("unavailable", "Docker create failed: " .. tostring(create_error)) end
    local container_id = bounds.text(created.Id, 64)
    if not container_id or #container_id ~= 64 or not container_id:match("^[0-9a-f]+$") then
        return nil, failure("unavailable", "Docker create returned no usable container ID")
    end
    local created_identity: Expected = {container_id = container_id :: string, image_id = identity.image_id,
        apparmor = identity.apparmor, started_at = nil, labels = identity.labels}
    local observed, observe_error = observe(client :: Client, created_identity)
    if not observed then
        if observe_error then observe_error.container_id = container_id end
        return nil, observe_error :: Failure
    end
    return observed, nil
end

function M.start(value: unknown): (Observation?, Failure?)
    local request, request_error = ref(value, "start")
    if not request then return nil, request_error end
    local client, client_error = connect()
    if not client then return nil, client_error end
    local before, before_error = observe(client :: Client, request.expected)
    if not before then return nil, before_error end
    if before.state == "running" then return before, nil end
    if before.state ~= "created" then return before, failure("mismatch", "Docker start requires a created container") end
    local started, start_error = (client :: Client):start_container(request.container_id)
    if not started then
        local reconciled, reconcile_error = observe(client :: Client, request.expected)
        if reconciled and reconciled.state == "running" then return reconciled, nil end
        return reconciled, reconcile_error or failure("unavailable", "Docker start failed: " .. tostring(start_error))
    end
    return observe(client :: Client, request.expected)
end

function M.stop(value: unknown): (Observation?, Failure?)
    local raw, raw_error = object(value, "stop")
    if not raw then return nil, raw_error end
    local unknown = bounds.fields(raw, {"container_id", "expected", "timeout_seconds"})
    if unknown then return nil, failure("invalid", "stop: " .. unknown) end
    local request, request_error = ref(raw, "stop", true)
    if not request then return nil, request_error end
    local timeout = bounds.integer(raw.timeout_seconds == nil and 10 or raw.timeout_seconds)
    if not timeout or timeout < 0 or timeout > 60 then return nil, failure("invalid", "stop.timeout_seconds must be between 0 and 60") end
    local client, client_error = connect()
    if not client then return nil, client_error end
    local before, before_error = observe(client :: Client, request.expected)
    if not before then return nil, before_error end
    if before.state == "exited" or before.state == "created" then return before, nil end
    if before.state ~= "running" then return before, failure("mismatch", "Docker stop requires a running container") end
    local stopped, stop_error = (client :: Client):stop_container(request.container_id, timeout :: integer)
    if not stopped then
        local reconciled, reconcile_error = observe(client :: Client, request.expected)
        if reconciled and reconciled.state == "exited" then return reconciled, nil end
        return reconciled, reconcile_error or failure("unavailable", "Docker stop failed: " .. tostring(stop_error))
    end
    return observe(client :: Client, request.expected)
end

function M.remove(value: unknown): (boolean?, Failure?)
    local request, request_error = ref(value, "remove")
    if not request then return nil, request_error end
    local client, client_error = connect()
    if not client then return nil, client_error end
    local before, before_error = observe(client :: Client, request.expected)
    if not before then
        if before_error and before_error.kind == "absent" then return true, nil end
        return nil, before_error
    end
    if before.state ~= "created" and before.state ~= "exited" then
        return nil, failure("mismatch", "Docker remove requires a stopped container")
    end
    local removed, remove_error = (client :: Client):remove_container(request.container_id, false)
    if not removed then
        local _, absent_error = inspect_raw(client :: Client, request.container_id)
        if absent_error and absent_error.kind == "absent" then return true, nil end
        return nil, absent_error or failure("unavailable", "Docker remove failed: " .. tostring(remove_error))
    end
    local _, absent_error = inspect_raw(client :: Client, request.container_id)
    if absent_error and absent_error.kind == "absent" then return true, nil end
    if absent_error then return nil, absent_error end
    return nil, failure("unavailable", "Docker remove did not confirm container absence")
end

return M
