-- SPDX-License-Identifier: MIT
local json = require("json")
local toml = require("toml")
local formats = require("formats")
local bounds = require("bounds")
local types = require("types")
local M = {}
type Context = {roots: {string}, files: {[string]: string}, strict: boolean, changed: boolean}
local function safe_path(path: string): boolean
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return false end
    end
    return not path:find("\0", 1, true) and not path:find("//", 1, true)
end
local function dependency(value: unknown, context: Context, depth: integer): (unknown, string?)
    if depth > 32 then return nil, "configuration nesting exceeds the projection limit" end
    if type(value) == "string" then
        local reference = value:match("^{file:([^}]+)}$")
        if reference then
            if not safe_path(reference) then return nil, "configuration dependency path is invalid" end
            local selected = context.files[reference]
            if selected then context.changed = true; return "{file:" .. selected .. "}", nil end
            return nil, "configuration names an undeclared or absent file dependency"
        end
        if (context.strict and value:find("~/", 1, true)) or value:sub(1, 2) == "~/"
            or value:find("${", 1, true) or value:find("{file:", 1, true) or value:find("{env:", 1, true) then
            return nil, "configuration contains an unresolved host file or environment reference"
        end
        if value:sub(1, 1) == "/" then
            if not safe_path(value) then return nil, "configuration path escapes the projection" end
            local selected = context.files[value]
            if selected then context.changed = true; return selected, nil end
            if context.strict then
                for _, root in ipairs(context.roots) do
                    if value == root or value:sub(1, #root + 1) == root .. "/" then return value, nil end
                end
                return nil, "configuration references an absolute path outside the projection"
            end
        end
    elseif type(value) == "table" then
        for key, child in pairs(value) do
            if context.strict and type(key) == "string" then
                local name = key:lower()
                if name:find("command", 1, true) or name == "hooks" or name == "plugin" or name == "plugins" or name == "include" or name == "includes" then
                    return nil, "configuration contains host execution or include settings; declare a portable configuration"
                end
            end
            local projected, reason = dependency(child, context, depth + 1)
            if reason then return nil, reason end
            value[key] = projected
        end
    end
    return value, nil
end
local function project(home: types.ProviderHome?, format: formats.Format, context: Context, host_home: string?, target_home: string?): (formats.Format?, string?)

    local result, decode_error = formats.decode(format)
    if not result then return nil, decode_error end
    local file = result.file
    if not file then return nil, "container projection requires a file format" end
    if home and host_home and target_home then
        for _, declared in ipairs(home.files) do
            if declared.source_path then
                for _, item in ipairs(file.initialize) do
                    if item.source_path == declared.source_path and item.path == declared.path then
                        context.files[host_home .. "/" .. declared.source_path] = target_home .. "/" .. declared.path
                        context.files["~/" .. declared.source_path] = target_home .. "/" .. declared.path
                    end
                end
            end
        end
    end
    for _, item in ipairs(file.initialize) do
        if item.source_path then
            local omit: {string}? = nil
            local clean: string? = nil
            for _, declared in ipairs(home and home.files or {}) do
                if declared.kind == "config" and declared.path == item.path then clean = declared.container_content; omit = declared.container_omit end
            end
            if context.strict and clean ~= nil then item.content = clean end
            local decoded: unknown = nil
            local parse_error: unknown = nil
            local content: unknown = item.content
            if type(content) ~= "string" then return nil, "container projection content is not text" end
            if item.path:sub(-5) == ".toml" then
                if item.content == "" then decoded = {} else decoded, parse_error = toml.decode(content) end
            elseif item.path:sub(-5) == ".json" then
                if item.content == "" then decoded = {} else decoded, parse_error = json.decode(content) end
            elseif not context.strict then
                goto continue
            else
                return nil, item.path .. ": projection configuration format is not supported"
            end
            if decoded == nil or parse_error then return nil, item.path .. ": Docker configuration could not be decoded" end
            if context.strict and omit then
                local document = bounds.object(decoded)
                if not document then return nil, item.path .. ": Docker configuration must be an object" end
                for _, key in ipairs(omit) do document[key] = nil end
                local encoded: string? = nil
                local content: unknown = item.content
            if type(content) ~= "string" then return nil, "container projection content is not text" end
            if item.path:sub(-5) == ".toml" then encoded = toml.encode(document) else encoded = json.encode(document) end
                if not encoded then return nil, item.path .. ": Docker configuration could not be encoded" end
                item.content = encoded
            end
            context.changed = false
            local projected, reason = dependency(decoded, context, 0)
            if reason then return nil, item.path .. ": " .. reason end
            local encoded: string? = nil
            local content: unknown = item.content
            if type(content) ~= "string" then return nil, "container projection content is not text" end
            if item.path:sub(-5) == ".toml" then encoded = toml.encode(projected) else encoded = json.encode(projected) end
            if not encoded then return nil, item.path .. ": projected configuration could not be encoded" end
            if context.changed then item.content = encoded end
        end
        ::continue::
    end
    return result, nil
end
function M.container(home: types.ProviderHome?, format: formats.Format, roots: {string}): (formats.Format?, string?)
    return project(home, format, {roots = roots, files = {}, strict = true, changed = false}, nil, nil)
end
function M.native(home: types.ProviderHome?, format: formats.Format, host_home: string, target_home: string): (formats.Format?, string?)
    return project(home, format, {roots = {}, files = {}, strict = false, changed = false}, host_home, target_home)
end
return M
