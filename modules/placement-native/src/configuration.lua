-- SPDX-License-Identifier: MIT
-- Fill admitted JSON credential fields only at native materialization. The
-- frozen delivery remains a token-free template; errors never contain values.
local json = require("json")
local toml = require("toml")
local bounds = require("bounds")
local canonical = require("canonical")
local types = require("types")
local M = {}
type Object = {[string]: unknown}

local function decode_toml(content: string, empty: boolean): (Object?, string?)
    if empty and content == "" then return {}, nil end
    local decoded, decode_error = toml.decode(content)
    local object = bounds.object(decoded)
    if not object then return nil, tostring(decode_error or "TOML document is not an object") end
    return object, nil
end

local function exact_subtree(document: Object, path: {string}): (unknown, string?)
    local current = document
    for index, segment in ipairs(path) do
        local count = 0
        for key in pairs(current) do
            count = count + 1
            if key ~= segment then return nil, "source contains data outside the selected TOML path" end
        end
        if count ~= 1 then return nil, "source does not contain the selected TOML path" end
        local value = current[segment]
        if value == nil then return nil, "source does not contain the selected TOML path" end
        if index == #path then return value, nil end
        local child = bounds.object(value)
        if not child then return nil, "source TOML path is not a table" end
        current = child
    end
    return nil, "selected TOML path is empty"
end

local function insert_missing(document: Object, path: {string}, selected: unknown): string?
    local current = document
    for index, segment in ipairs(path) do
        local value = current[segment]
        if index == #path then
            if value ~= nil then return "selected TOML path already exists" end
            current[segment] = selected
            return nil
        end
        if value == nil then
            local child: Object = {}
            current[segment] = child
            current = child
        else
            local child = bounds.object(value)
            if not child then return "selected TOML path crosses a non-table value" end
            current = child
        end
    end
    return "selected TOML path is empty"
end

local function compose_toml(base: string, path: {string}, source: string): (string?, string?)
    local document, document_error = decode_toml(base, true)
    if not document then return nil, "decode base TOML: " .. tostring(document_error) end
    local overlay, overlay_error = decode_toml(source, false)
    if not overlay then return nil, "decode source TOML: " .. tostring(overlay_error) end
    local selected, selection_error = exact_subtree(overlay, path)
    if selection_error then return nil, selection_error end
    local insert_error = insert_missing(document, path, selected)
    if insert_error then return nil, insert_error end
    local encoded, encode_error = toml.encode(document)
    if not encoded then return nil, "encode composed TOML: " .. tostring(encode_error) end
    return encoded, nil
end

-- The driver owns each recipe's selected paths. This is deliberately not a
-- general JSON merge: it can only retain an equal default, insert a missing
-- leaf, or append one array.
local function json_object(value: unknown, label: string): (Object?, string?)
    local object = bounds.object(value)
    if not object then return nil, label .. " must be a JSON object" end
    local encoded, encode_error = canonical.encode(object)
    if not encoded or encode_error or encoded:sub(1, 1) ~= "{" then return nil, label .. " must be a JSON object" end
    return object, nil
end

local function json_array(value: unknown, label: string): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be a JSON array" end
    local list = value :: {unknown}
    local count = 0
    local highest = 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, label .. " must be a JSON array" end
        count = count + 1
        if key > highest then highest = key end
    end
    if count ~= highest then return nil, label .. " must be a dense JSON array" end
    local encoded, encode_error = canonical.encode(list)
    if not encoded or encode_error or encoded:sub(1, 1) ~= "[" then return nil, label .. " must be a JSON array" end
    return list, nil
end

local function decode_json_object(content: string, label: string, empty: boolean): (Object?, string?)
    if empty and content == "" then return table.create(0, 1) :: Object, nil end
    local decoded, decode_error = json.decode(content)
    local object, object_error = json_object(decoded, label)
    if not object then return nil, tostring(decode_error or object_error) end
    return object, nil
end

local function selected_json_path(document: Object, path: {string}, label: string): (unknown, string?)
    local current = document
    for index, segment in ipairs(path) do
        local value = current[segment]
        if value == nil then return nil, label .. " is missing" end
        if index == #path then return value, nil end
        local child, child_error = json_object(value, label)
        if not child then return nil, child_error end
        current = child
    end
    return nil, label .. " is missing"
end

local function target_parent(document: Object, path: {string}): (Object?, string?)
    local current = document
    for index = 1, #path - 1 do
        local key = path[index]
        local value = current[key]
        if value == nil then
            local child: Object = table.create(0, 1) :: Object
            current[key] = child
            current = child
        else
            local child, child_error = json_object(value, "base JSON recipe path")
            if not child then return nil, child_error end
            current = child
        end
    end
    return current, nil
end

local function rebuild_patch_source(source: Object, operations: {types.JsonOperation}): (Object?, string?)
    local rebuilt: Object = table.create(0, 1) :: Object
    for _, operation in ipairs(operations) do
        local selected, selected_error = selected_json_path(source, operation.path, "source JSON recipe path")
        if selected == nil then return nil, selected_error end
        local parent, parent_error = target_parent(rebuilt, operation.path)
        if not parent then return nil, parent_error end
        local key = operation.path[#operation.path]
        if parent[key] ~= nil then return nil, "source JSON recipe paths overlap" end
        parent[key] = selected
    end
    local encoded_source, source_encode_error = canonical.encode(source)
    local encoded_rebuilt, rebuilt_encode_error = canonical.encode(rebuilt)
    if not encoded_source or source_encode_error or not encoded_rebuilt or rebuilt_encode_error then return nil, "encode JSON patch source" end
    if encoded_source ~= encoded_rebuilt then return nil, "source JSON contains data outside the selected recipe paths" end
    return rebuilt, nil
end

local function compose_json_patch(base: string, source: string, operations: {types.JsonOperation}): (string?, string?)
    local document, document_error = decode_json_object(base, "base JSON configuration", true)
    if not document then return nil, "decode base JSON: " .. tostring(document_error) end
    local overlay, overlay_error = decode_json_object(source, "source JSON configuration", false)
    if not overlay then return nil, "decode source JSON: " .. tostring(overlay_error) end
    local patch, patch_error = rebuild_patch_source(overlay, operations)
    if not patch then return nil, patch_error end
    for _, operation in ipairs(operations) do
        local selected, selected_error = selected_json_path(patch, operation.path, "source JSON recipe path")
        if selected == nil then return nil, selected_error end
        local parent, parent_error = target_parent(document, operation.path)
        if not parent then return nil, parent_error end
        local key = operation.path[#operation.path]
        if operation.kind == "default" then
            if parent[key] == nil then
                parent[key] = selected
            else
                local prior_encoded = canonical.encode(parent[key])
                local selected_encoded = canonical.encode(selected)
                if not prior_encoded or not selected_encoded or prior_encoded ~= selected_encoded then
                    return nil, "base JSON recipe default path differs"
                end
            end
        elseif operation.kind == "insert" then
            if parent[key] ~= nil then return nil, "base JSON recipe insert path already exists" end
            parent[key] = selected
        else
            local additions, additions_error = json_array(selected, "source JSON recipe append path")
            if not additions then return nil, additions_error end
            local prior = parent[key]
            if prior == nil then
                parent[key] = additions
            else
                local retained, retained_error = json_array(prior, "base JSON recipe append path")
                if not retained then return nil, retained_error end
                for _, item in ipairs(additions) do retained[#retained + 1] = item end
            end
        end
    end
    local encoded, encode_error = canonical.encode(document)
    if not encoded then return nil, "encode composed JSON configuration: " .. tostring(encode_error) end
    return encoded .. "\n", nil
end

function M.overlaps(files: {types.Configuration}, protected: {string}): boolean
    for _, file in ipairs(files) do
        for _, path in ipairs(protected) do
            if file.path == path or file.path:sub(1, #path + 1) == path .. "/" or path:sub(1, #file.path + 1) == file.path .. "/" then return true end
        end
    end
    return false
end
function M.render(file: types.Configuration, environment: {[string]: string}, gateway: types.Gateway?, base: string?): (string?, string?)
    local content = file.content
    if file.secret_fields then
        if not gateway or file.provider_ref ~= "bee:gateway_endpoint" then return nil, "configuration secret fields require the admitted gateway" end
        local decoded, decode_error = json.decode(file.content)
        local root = bounds.object(decoded)
        if decode_error or not root then return nil, "secret configuration must be a JSON object" end
        for _, field in ipairs(file.secret_fields) do
            if field.environment ~= gateway.destination and field.environment ~= gateway.hook_destination then return nil, "configuration credential is not admitted" end
            local secret = environment[field.environment]
            if not secret or secret == "" or #secret > 8192 then return nil, "configuration credential is unavailable" end
            local parent = root
            for index = 1, #field.path - 1 do
                local child = bounds.object(parent[field.path[index]])
                if not child then return nil, "configuration secret path is not an object" end
                parent = child
            end
            local key = field.path[#field.path]
            if not key or parent[key] ~= "" then return nil, "configuration secret target must be an empty string" end
            parent[key] = field.prefix .. secret
        end
        local encoded, encode_error = canonical.encode(root)
        if not encoded or encode_error or #encoded + 1 > 8192 then return nil, "materialized configuration exceeds its encoding bound" end
        content = encoded .. "\n"
    end
    if file.composition then
        if base == nil then return nil, "configuration composition base is missing" end
        if #base > 131072 then return nil, "configuration composition base exceeds byte limit" end
        local composed: string?
        local compose_error: string?
        if file.composition.kind == "toml_insert" then
            composed, compose_error = compose_toml(base, file.composition.path, content)
            if not composed then return nil, "compose TOML configuration: " .. tostring(compose_error) end
        elseif file.composition.kind == "json_patch" then
            composed, compose_error = compose_json_patch(base, content, file.composition.operations)
            if not composed then return nil, "compose JSON configuration: " .. tostring(compose_error) end
        else
            return nil, "configuration composition is unsupported"
        end
        if #composed > 131072 then return nil, "composed configuration exceeds byte limit" end
        content = composed
    elseif base ~= nil then
        return nil, "configuration supplied an unexpected base"
    end
    return content, nil
end
return M
