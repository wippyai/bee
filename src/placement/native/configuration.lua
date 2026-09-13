-- SPDX-License-Identifier: MIT
-- Fill admitted JSON credential fields only at native materialization. The
-- frozen delivery remains a token-free template; errors never contain values.
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local types = require("types")
local M = {}
function M.overlaps(files: {types.Configuration}, protected: {string}): boolean
    for _, file in ipairs(files) do
        for _, path in ipairs(protected) do
            if file.path == path or file.path:sub(1, #path + 1) == path .. "/" or path:sub(1, #file.path + 1) == file.path .. "/" then return true end
        end
    end
    return false
end
function M.render(file: types.Configuration, environment: {[string]: string}, gateway: types.Gateway?): (string?, string?)
    if not file.secret_fields then return file.content, nil end
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
    local content, encode_error = canonical.encode(root)
    if not content or encode_error or #content + 1 > 8192 then return nil, "materialized configuration exceeds its encoding bound" end
    return content .. "\n", nil
end
return M
