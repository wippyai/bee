-- SPDX-License-Identifier: MIT
-- Pure decoder for the facts an admitting owner needs from Docker inspect.
-- It performs no daemon I/O and does not infer lifecycle state from transport
-- errors or from an absent response.
local bounds = require("bounds")
local time = require("time")
local M = {}

type Labels = {[string]: string}
type Expected = {container_id: string, image_id: string, apparmor: string, started_at: string?, labels: Labels}
type Observation = {
    container_id: string, image_id: string, started_at: string?,
    state: "created" | "running" | "exited", exit_code: integer?, labels: Labels,
}
type Object = {[string]: unknown}

local MAX_LABELS = 256

local function hex(value: unknown, length: integer): string?
    local text = bounds.text(value, length)
    if not text or #text ~= length or not text:match("^[0-9a-f]+$") then return nil end
    return text
end

local function image(value: unknown): string?
    local text = bounds.text(value, 71)
    if not text or #text ~= 71 or not text:match("^sha256:[0-9a-f]+$") then return nil end
    return text
end

local function timestamp(value: unknown): (string?, boolean?)
    local text = bounds.text(value, 64)
    if not text then return nil, nil end
    local parsed, parse_error = time.parse(time.RFC3339NANO, text)
    if parsed == nil or parse_error ~= nil then return nil, nil end
    return text, parsed:is_zero()
end

local function expected_labels(value: unknown): (Labels?, string?)
    local object = bounds.object(value)
    if not object then return nil, "Docker expected labels must be an object" end
    local labels: Labels = {}
    local count = 0
    for key, raw in pairs(object) do
        if #key == 0 or #key > 256 or key:find("%c") then return nil, "invalid Docker expected label" end
        local label = bounds.text(raw, 4096)
        if not label or label == "" or label:find("%c") then return nil, "invalid Docker expected label" end
        count = count + 1
        if count > 32 then return nil, "Docker expected labels exceed their bound" end
        labels[key] = label
    end
    if count == 0 then return nil, "Docker expected labels are required" end
    return labels, nil
end

local function expected(value: unknown): (Expected?, string?)
    local object = bounds.object(value)
    if not object then return nil, "Docker inspection expectation must be an object" end
    local unknown_field = bounds.fields(object, {"container_id", "image_id", "apparmor", "started_at", "labels"})
    if unknown_field then return nil, unknown_field end
    local container_id = hex(object.container_id, 64)
    if not container_id then return nil, "Docker expected container ID must be full lowercase hex" end
    local image_id = image(object.image_id)
    if not image_id then return nil, "Docker expected image ID must be a full sha256 ID" end
    local apparmor = bounds.text(object.apparmor, 128)
    if not apparmor or not apparmor:match("^[A-Za-z0-9_.-]+$") or apparmor == "unconfined" then
        return nil, "Docker expected AppArmor profile is invalid"
    end
    local started_at: string? = nil
    if object.started_at ~= nil then
        local parsed, zero = timestamp(object.started_at)
        if not parsed or zero then return nil, "Docker expected execution start time is invalid" end
        started_at = parsed
    end
    local labels, labels_error = expected_labels(object.labels)
    if not labels then return nil, labels_error end
    local result: Expected = {container_id = container_id, image_id = image_id, apparmor = apparmor :: string,
        started_at = started_at, labels = labels}
    return result, nil
end

local function actual_labels(value: unknown, expected_values: Labels): (Labels?, string?)
    local object = bounds.object(value)
    if not object then return nil, "Docker inspection is missing Config.Labels" end
    local count = 0
    for _ in pairs(object) do
        count = count + 1
        if count > MAX_LABELS then return nil, "Docker inspection labels exceed their bound" end
    end
    local labels: Labels = {}
    for key in pairs(expected_values) do
        local label = bounds.text(object[key], 4096)
        if not label or label == "" or label:find("%c") then return nil, "Docker container admission labels changed" end
        if label ~= expected_values[key] then return nil, "Docker container admission labels changed" end
        labels[key] = label
    end
    return labels, nil
end

function M.decode(value: unknown, expected_value: unknown): (Observation?, string?)
    local expected_identity, expected_error = expected(expected_value)
    if not expected_identity then return nil, expected_error end
    local object = bounds.object(value)
    if not object then return nil, "Docker inspection must be an object" end
    local container_id = hex(object.Id, 64)
    if not container_id then return nil, "Docker inspection has no full container ID" end
    if container_id ~= expected_identity.container_id then return nil, "Docker container identity changed" end
    local image_id = image(object.Image)
    if not image_id then return nil, "Docker inspection has no full image ID" end
    if image_id ~= expected_identity.image_id then return nil, "Docker container image changed" end
    local config = bounds.object(object.Config)
    if not config then return nil, "Docker inspection is missing Config" end
    local labels, labels_error = actual_labels(config.Labels, expected_identity.labels)
    if not labels then return nil, labels_error end
    local state = bounds.object(object.State)
    if not state then return nil, "Docker inspection is missing State" end
    local status = bounds.text(state.Status, 32)
    if status ~= "created" and status ~= "running" and status ~= "exited" then
        return nil, "Docker inspection has an unsupported container state"
    end
    local started_at, started_zero = timestamp(state.StartedAt)
    if not started_at then return nil, "Docker inspection has an invalid StartedAt" end
    local exit_code = bounds.integer(state.ExitCode)
    if not exit_code or exit_code < 0 then return nil, "Docker inspection has an invalid ExitCode" end
    if status == "created" then
        if started_zero ~= true or exit_code ~= 0 or expected_identity.started_at ~= nil then
            return nil, "created Docker container has execution state"
        end
        local observation: Observation = {container_id = container_id, image_id = image_id,
            started_at = nil, state = "created", labels = labels}
        return observation, nil
    end
    if started_zero == true then return nil, "Docker execution has no start time" end
    if expected_identity.started_at ~= nil and started_at ~= expected_identity.started_at then
        return nil, "Docker execution start time changed"
    end
    local apparmor = bounds.text(object.AppArmorProfile, 128)
    if apparmor ~= expected_identity.apparmor then return nil, "Docker AppArmor profile is not enforced" end
    if status == "running" then
        local observation: Observation = {container_id = container_id, image_id = image_id,
            started_at = started_at, state = "running", labels = labels}
        return observation, nil
    end
    local observation: Observation = {container_id = container_id, image_id = image_id,
        started_at = started_at, state = "exited", exit_code = exit_code, labels = labels}
    return observation, nil
end

return M
