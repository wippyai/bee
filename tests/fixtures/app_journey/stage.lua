-- MIT. Stage the next application definition for the live journey.
-- This command is deliberately limited to authoring, publication and staging:
-- review, selection, approval, activation and overlay materialization remain
-- human and destination-owner actions in Overlays and Approvals.
local funcs = require("funcs")
local registry = require("registry")
local json = require("json")
local logger = require("logger")
local bounds = require("bounds")
local base64 = require("base64")

type Object = {[string]: unknown}

local SOURCE_WORKSPACE = "app-journey-source"
local COMPONENT = "bee.app_journey_demo/app"
local DEFINITION_ID = "bee.app_journey_demo:app"
local APP_TITLE = "App Journey"
local V2_VERSION = "1.0.1"

local function object(value: unknown, label: string): Object
    local decoded = bounds.object(value)
    if not decoded then error(label .. " must be an object") end
    return decoded
end

local function reply_of(target: string, request: unknown): Object
    local result, err = funcs.call(target, request)
    if err then error(target .. " call failed: " .. tostring(err)) end
    return object(result, target .. " reply")
end

local function call_api(target: string, request: unknown): Object
    local reply = reply_of(target, request)
    if reply.ok ~= true then
        error(target .. " returned error: " .. tostring(reply.code) .. ": " .. tostring(reply.message or json.encode(reply.error)))
    end
    return object(reply.value, target .. " value")
end

local function workspace_value(operation: string, workspace_id: string, expected_revision: integer?, key: string?, content: string?,
    offset: integer?, limit: integer?): Object
    local request: Object = {operation = operation, overlay_id = workspace_id}
    if expected_revision ~= nil then request.expected_revision = expected_revision end
    if key then request.idempotency_key = key end
    if operation == "put" then request.path, request.content = "entries.json", content end
    if operation == "read" then
        request.path = "entries.json"
        if offset ~= nil then request.offset = offset end
        if limit ~= nil then request.limit = limit end
    end
    return call_api("bee.governance.binding:overlay_call", request)
end

local function read_entries(): {Object}
    local chunks: {string} = {}
    local offset = 0
    local expected_bytes: integer? = nil
    local expected_digest: string? = nil
    while true do
        local file = workspace_value("read", SOURCE_WORKSPACE, nil, nil, nil, offset, 16384)
        local encoded = file.content_base64
        if type(encoded) ~= "string" then error("source workspace omitted entries.json bytes") end
        local bytes, decode_error = base64.decode(encoded)
        if not bytes or decode_error then error("decode source entries: " .. tostring(decode_error)) end
        local file_bytes = bounds.count(file.bytes)
        local file_digest = type(file.digest) == "string" and file.digest or nil
        if not file_bytes or file_bytes < 1 or file_bytes > 4 * 1024 * 1024
            or not file_digest or #file_digest ~= 64 or not file_digest:match("^[0-9a-f]+$")
            or file.offset ~= offset or file.chunk_bytes ~= #bytes or type(file.eof) ~= "boolean" then
            error("source workspace returned an invalid entries.json window (offset=" .. tostring(file.offset)
                .. ", chunk_bytes=" .. tostring(file.chunk_bytes) .. ", bytes=" .. tostring(file.bytes)
                .. ", eof=" .. tostring(file.eof) .. ")")
        end
        if expected_bytes == nil then
            expected_bytes, expected_digest = file_bytes, file_digest
        elseif file_bytes ~= expected_bytes or file_digest ~= expected_digest then
            error("source entries changed between read windows")
        end
        if #bytes == 0 and file.eof ~= true then error("source workspace returned an empty nonfinal window") end
        chunks[#chunks + 1] = bytes
        offset = offset + #bytes
        if offset > file_bytes then error("source workspace returned bytes beyond entries.json") end
        if file.eof then
            if offset ~= file_bytes then error("source workspace ended before entries.json") end
            break
        end
        if offset >= file_bytes then error("source workspace omitted the end of entries.json") end
    end
    local decoded, json_error = json.decode(table.concat(chunks))
    if json_error or type(decoded) ~= "table" then error("source entries are not JSON: " .. tostring(json_error)) end
    local entries: {Object} = {}
    for index, raw in ipairs(decoded :: {unknown}) do entries[index] = object(raw, "source entry") end
    return entries
end

local function replacement_probe(): string
    return [[
    local stale_results = assert(process.listen("bee.app_open_probe.credentials.result", {message = true}))
    assert(operator, "replacement operator is unavailable")
    assert(process.send(operator, "bee.app_open_probe.credentials.get", {instance_id = launch.instance_id}))
    local stale: Object? = nil
    local stale_wait = time.after("2s")
    while true do
        local selected = channel.select({stale_results:case_receive(), stale_wait:case_receive()})
        if not selected.ok or selected.channel == stale_wait then break end
        local candidate = object(selected.value:payload():data(), "stale credential reply")
        if candidate.instance_id == launch.instance_id then stale = candidate; break end
    end
    if not stale or stale.error ~= nil then error("replacement did not receive the prior credentials") end
    if stale.launch_token ~= launch.launch_token or stale.execution_generation ~= launch.execution_generation then
        error("operator did not retain the current replacement credentials")
    end
    local previous_token = stale.previous_launch_token
    local previous_generation = stale.previous_execution_generation
    if type(previous_token) ~= "string" or previous_token == "" or #previous_token > 160
        or previous_token:find("%c") or type(previous_generation) ~= "number"
        or previous_generation ~= math.floor(previous_generation) or previous_generation < 1
        or previous_generation >= launch.execution_generation
        or previous_token == launch.launch_token then
        error("replacement credentials did not advance and rotate")
    end
    local stale_request = launch.instance_id .. "-stale-credential"
    assert(process.send(launch.broker_pid, "bee.application.thread.request", {
        version = 1, request_id = stale_request, instance_id = launch.instance_id,
        launch_token = previous_token, execution_generation = previous_generation,
        operation = "read", arguments = {cursor = 0, limit = 1}}))
    local rejected = true
    local stale_deadline = time.after("2s")
    while true do
        local selected = channel.select({thread_results:case_receive(), stale_deadline:case_receive()})
        if not selected.ok or selected.channel == stale_deadline then break end
        local candidate = selected.value:payload():data()
        if type(candidate) == "table" and candidate.request_id == stale_request then rejected = false; break end
    end
    process.unlisten(stale_results)
    if not rejected then error("stale credentials received a correlated broker result") end
    stale_status = "refused"; paint()
]]
end

local function entries_for(version: string, source: string): {Object}
    local entries = read_entries()
    local found = false
    for _, entry in ipairs(entries) do
        if entry.id == DEFINITION_ID then
            found = true
            local data = object(entry.data, "application data")
            data.source = source
            entry.data = data
            local meta = object(entry.meta, "application metadata")
            local application = object(meta.application, "application descriptor")
            application.revision = version == V2_VERSION and "2" or "3"
            application.title = version == V2_VERSION and "Agent App Updated" or APP_TITLE
            meta.application = application
            entry.meta = meta
        end
    end
    if not found then error("source workspace has no " .. DEFINITION_ID) end
    return entries
end

local function stage_version(workspace_id: string, workspace: string, version: string, source: string): Object
    local current = workspace_value("read", workspace, nil, nil, nil)
    local revision = bounds.count(current.revision)
    if not revision then error("source workspace omitted its revision") end
    local measured = workspace_value("put", workspace, revision, "put-" .. version,
        json.encode(entries_for(version, source)))
    local next_revision = bounds.count(measured.revision)
    if not next_revision or next_revision ~= revision + 1 then error("workspace put did not advance its revision") end
    local frozen = workspace_value("freeze", workspace, next_revision, "freeze-" .. version, nil)
    local snapshot_digest = bounds.id(frozen.digest)
    if not snapshot_digest then error("workspace freeze omitted its digest") end
    local published = call_api("bee.governance.binding:publication_call", {operation = "prepare", workspace_id = workspace_id,
        component = COMPONENT, version = version, snapshot_digest = snapshot_digest})
    local descriptor = object(published.descriptor, "published descriptor")
    local available = call_api("bee.governance.binding:destination_call", {operation = "available", workspace_id = workspace_id})
    local found = false
    for _, raw in ipairs(available.versions :: {unknown}) do
        local item = object(raw, "available version")
        if item.key == descriptor.key and item.digest == descriptor.digest then found = true end
    end
    if not found then error("published replacement was not discoverable") end
    local staged = call_api("bee.governance.binding:destination_call", {operation = "stage", workspace_id = workspace_id,
        source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
        descriptor_digest = descriptor.digest, idempotency_key = "stage-" .. workspace})
    if staged.status ~= "staged" or staged.selected == true then error("replacement was not staged only") end
    return {workspace = workspace, version = version, snapshot_digest = snapshot_digest,
        artifact_digest = staged.artifact_digest, plan_digest = staged.plan_digest}
end

local function main()
    local activation = assert(registry.get("bee:governance_activation_profiles"))
    local data = object(activation.data, "activation profiles")
    local first = object((data.profiles :: {unknown})[1], "initial activation profile")
    local workspace_id = bounds.id(first.workspace_id)
    if not workspace_id then error("initial activation profile identity is missing") end
    local entries = read_entries()
    local source = ""
    for _, entry in ipairs(entries) do
        if entry.id == DEFINITION_ID then source = object(entry.data, "application data").source :: string end
    end
    if source == "" then error("source application has no source") end
    local v2_source = source:gsub("APP JOURNEY DELIVERED", "AGENT APP UPDATED")
    v2_source = v2_source:gsub("%-%- APP_JOURNEY_REPLACEMENT_PROBE", replacement_probe(), 1)
    local result = stage_version(workspace_id, SOURCE_WORKSPACE, V2_VERSION, v2_source)
    logger:info("APP_JOURNEY_REPLACEMENT_STAGED", result)
end

return {main = function(...)
    local ok, err = pcall(main, ...)
    if not ok then
        logger:info("APP_JOURNEY_REPLACEMENT_FAILED", {error = tostring(err)})
        error(err)
    end
end}
