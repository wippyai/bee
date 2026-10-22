-- MIT. Compose a delivered configuration file onto the base the host keeps
-- for it: copy the base, insert a TOML subtree, or patch a JSON or TOML
-- document at the paths its operations name. A home without a base composes
-- onto an empty document.
local json = require("json")
local toml = require("toml")
local bounds = require("bounds")
local canonical = require("canonical")
local configuration_types = require("configuration_types")
local M = {}
type Object = {[string]: unknown}
M.MAX_BYTES = 131072

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

local function insert_missing(document: Object, path: {string}, selected: unknown, append_text: boolean?): string?
    local current = document
    for index, segment in ipairs(path) do
        local value = current[segment]
        if index == #path then
            if append_text then
                if type(selected) ~= "string" or (value ~= nil and type(value) ~= "string") then return "selected TOML append path must contain text" end
                current[segment] = type(value) == "string" and value ~= "" and (value .. "\n\n" .. selected) or selected
                return nil
            end
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

local function compose_toml(base: string, path: {string}, source: string, append_text: boolean?): (string?, string?)
    local document, document_error = decode_toml(base, true)
    if not document then return nil, "decode base TOML: " .. tostring(document_error) end
    local overlay, overlay_error = decode_toml(source, false)
    if not overlay then return nil, "decode source TOML: " .. tostring(overlay_error) end
    local selected, selection_error = exact_subtree(overlay, path)
    if selection_error then return nil, selection_error end
    local insert_error = insert_missing(document, path, selected, append_text)
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
    local list = value
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
    if empty and content == "" then return table.create(0, 1), nil end
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
            local child: Object = table.create(0, 1)
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

local function rebuild_patch_source(source: Object, operations: {configuration_types.JsonOperation}): (Object?, string?)
    local rebuilt: Object = table.create(0, 1)
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

local function compose_json_patch(base: string, source: string, operations: {configuration_types.JsonOperation}, format: string?): (string?, string?)
    local document: Object?
    local overlay: Object?
    local document_error: string?
    local overlay_error: string?
    if format == "toml" then
        document, document_error = decode_toml(base, true)
        overlay, overlay_error = decode_toml(source, false)
    else
        document, document_error = decode_json_object(base, "base JSON configuration", true)
        overlay, overlay_error = decode_json_object(source, "source JSON configuration", false)
    end
    if not document then return nil, "decode base configuration: " .. tostring(document_error) end
    if not overlay then return nil, "decode source configuration: " .. tostring(overlay_error) end
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
        elseif operation.kind == "set" then
            parent[key] = selected
        elseif operation.kind == "insert" then
            if parent[key] ~= nil then return nil, "base JSON recipe insert path already exists" end
            parent[key] = selected
        elseif type(selected) == "string" then
            local prior = parent[key]
            if prior ~= nil and type(prior) ~= "string" then return nil, "base recipe append path must contain text" end
            parent[key] = type(prior) == "string" and prior ~= "" and (prior .. "\n\n" .. selected) or selected
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
    local encoded: string?
    local encode_error: unknown
    if format == "toml" then encoded, encode_error = toml.encode(document)
    else encoded, encode_error = canonical.encode(document) end
    if not encoded then return nil, "encode composed JSON configuration: " .. tostring(encode_error) end
    return encoded .. "\n", nil
end

-- compose returns the file content composed onto base.
function M.compose(composition: configuration_types.Composition, content: string, base: string): (string?, string?)
    if #base > M.MAX_BYTES then return nil, "configuration composition base exceeds byte limit" end
    local composed: string?
    local compose_error: string?
    if composition.kind == "copy" then
        if content ~= "" then return nil, "copy composition requires empty content" end
        composed = base
    elseif composition.kind == "toml_insert" then
        composed, compose_error = compose_toml(base, composition.path, content, composition.append_text)
        if not composed then return nil, "compose TOML configuration: " .. tostring(compose_error) end
    elseif composition.kind == "json_patch" or composition.kind == "toml_patch" then
        composed, compose_error = compose_json_patch(base, content, composition.operations, composition.kind == "toml_patch" and "toml" or "json")
        if not composed then return nil, "compose JSON configuration: " .. tostring(compose_error) end
    else
        return nil, "configuration composition is unsupported"
    end
    if #composed > M.MAX_BYTES then return nil, "composed configuration exceeds byte limit" end
    return composed, nil
end
return M
