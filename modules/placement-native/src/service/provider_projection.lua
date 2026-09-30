-- SPDX-License-Identifier: MIT
local json = require("json")
local toml = require("toml")
local registry = require("registry")
local profiles = require("profiles")
local formats = require("formats")
local bounds = require("bounds")
local types = require("types")
local M = {}
function M.roots(ref: string): ({string}?, string?)
    local pinned, pin_error = registry.snapshot()
    if not pinned then return nil, tostring(pin_error) end
    local profile, profile_error = profiles.resolve(pinned, ref)
    if not profile then return nil, profile_error end
    local roots: {string} = {}
    for _, mount in ipairs(profile.profile.mounts) do roots[#roots + 1] = mount.target end
    return roots, nil
end
local function dependency(value: unknown, roots: {string}, depth: integer): string?
    if depth > 32 then return "configuration nesting exceeds the projection limit" end
    if type(value) == "string" then
        if value:find("~/", 1, true) or value:find("${", 1, true) or value:find("{file:", 1, true) or value:find("{env:", 1, true) then
            return "configuration contains an unresolved host file or environment reference"
        end
        if value:sub(1, 1) == "/" then
            for segment in value:gmatch("[^/]+") do
                if segment == ".." then return "configuration path escapes the Docker projection" end
            end
            for _, root in ipairs(roots) do
                if value == root or value:sub(1, #root + 1) == root .. "/" then return nil end
            end
            return "configuration references an absolute path outside the Docker projection"
        end
    elseif type(value) == "table" then
        for key, child in pairs(value) do
            if type(key) == "string" then
                local name = key:lower()
                if name:find("command", 1, true) or name == "hooks" or name == "plugin" or name == "plugins" or name == "include" or name == "includes" then
                    return "configuration contains host execution or include settings; use a clean login-based config or declare a container configuration"
                end
            end
            local reason = dependency(child, roots, depth + 1)
            if reason then return reason end
        end
    end
    return nil
end
function M.container(home: types.ProviderHome?, format: formats.Format, roots: {string}): (formats.Format?, string?)
    local result, decode_error = formats.decode(format)
    if not result then return nil, decode_error end
    local file = result.file
    if not file then return nil, "container projection requires a file format" end
    for _, item in ipairs(file.initialize) do
        if item.source_path then
            local omit: {string}? = nil
            local clean: string? = nil
            for _, declared in ipairs(home and home.files or {}) do
                if declared.kind == "config" and declared.path == item.path then clean = declared.container_content; omit = declared.container_omit end
            end
            if clean ~= nil then item.content = clean end
            local decoded: unknown = nil
            local parse_error: unknown = nil
            if item.path:sub(-5) == ".toml" then
                if item.content == "" then decoded = {} else decoded, parse_error = toml.decode(item.content) end
            elseif item.path:sub(-5) == ".json" then
                if item.content == "" then decoded = {} else decoded, parse_error = json.decode(item.content) end
            else
                return nil, item.path .. ": Docker configuration format is not supported"
            end
            if decoded == nil or parse_error then return nil, item.path .. ": Docker configuration could not be decoded" end
            if omit then
                local document = bounds.object(decoded)
                if not document then return nil, item.path .. ": Docker configuration must be an object" end
                for _, key in ipairs(omit) do document[key] = nil end
                local encoded: string? = nil
                if item.path:sub(-5) == ".toml" then encoded = toml.encode(document) else encoded = json.encode(document) end
                if not encoded then return nil, item.path .. ": Docker configuration could not be encoded" end
                item.content = encoded
            end
            local reason = dependency(decoded, roots, 0)
            if reason then return nil, item.path .. ": " .. reason end
        end
    end
    return result, nil
end
return M
