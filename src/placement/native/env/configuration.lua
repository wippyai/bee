-- SPDX-License-Identifier: MIT
-- Fill admitted JSON credential fields only at native materialization. The
-- frozen delivery remains a token-free template; errors never contain values.
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local types = require("types")
local driver_configuration = require("driver_configuration")
local composition = require("composition")
local M = {}
type Object = {[string]: unknown}

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
        if not gateway or file.provider_ref ~= driver_configuration.GATEWAY_PROVIDER_REF then return nil, "configuration secret fields require the admitted gateway" end
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
        local composed, compose_error = composition.compose(file.composition, content, base)
        if not composed then return nil, compose_error end
        content = composed
    elseif base ~= nil then
        return nil, "configuration supplied an unexpected base"
    end
    return content, nil
end
return M
