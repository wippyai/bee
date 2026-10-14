-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local canonical = require("canonical")
local json = require("json")
local toml = require("toml")
local hash = require("hash")
local configuration = require("configuration")
local M = {}
type Object = {[string]: unknown}
type Document = {path: string, format: string, value: Object, text: string?, source: configuration.Configuration?, operations: {configuration.JsonOperation}, base_path: string?}

local function assign(document: Object, path: {string}, value: unknown, append: boolean): string?
    local current = document
    for index, key in ipairs(path) do
        if index == #path then
            local previous = current[key]
            if append and previous ~= nil then
                if type(previous) == "string" and type(value) == "string" then current[key] = previous .. "\n\n" .. value
                elseif type(previous) == "table" and type(value) == "table" then
                    local left, right = bounds.array(previous, 64), bounds.array(value, 64)
                    if not left or not right or #left + #right > 64 then return "config append needs bounded arrays" end
                    for _, item in ipairs(right) do left[#left + 1] = item end
                    current[key] = left
                else return "config append needs text or arrays" end
            else current[key] = value end
        else
            if current[key] == nil then current[key] = {} end
            local child = bounds.object(current[key])
            if not child then return "config path crosses a scalar" end
            current = child
        end
    end
    return nil
end

local function token_value(render: Object, value: unknown, values: Object): unknown
    local token = bounds.object(render.value)
    if not token then return nil end
    if token.literal ~= nil then return token.literal end
    if token.field == "provider.system_prompt_files" then return values.system_prompt_files end
    local name = type(token.field) == "string" and token.field:match("^provider%.env%.([A-Z][A-Z0-9_]*)$")
    if name then
        local environment = bounds.object(values.env)
        return environment and environment[name]
    end
    return value
end

function M.files(fields: Object, values: Object, context: string, files: {configuration.Configuration}): ({configuration.Configuration}?, string?)
    local documents: {[string]: Document} = {}
    local names: {string} = {}
    for name in pairs(fields) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local declaration = bounds.object(fields[name])
        local value = values[name]
        local renders = declaration and bounds.array(declaration.render, 8)
        if declaration and value ~= nil and renders then
            for _, raw in ipairs(renders) do
                local render = bounds.object(raw)
                local contexts = render and bounds.ids(render.contexts, true)
                if render and render.kind == "config" and contexts and bounds.member(context, contexts) then
                    local path = bounds.subpath(render.file)
                    local keys = bounds.ids(render.path, true)
                    if not path or not keys then return nil, "invalid OptionSpec configuration path" end
                    local document = documents[path]
                    if not document then
                        document = {path = path, format = tostring(render.format), value = {}, operations = {}}
                        for _, source in ipairs(files) do
                            if source.path == path then
                                local composition = source.composition
                                if composition then
                                    document.base_path = composition.base_path
                                    if composition.kind == "json_patch" or composition.kind == "toml_patch" then
                                        for _, operation in ipairs(composition.operations) do document.operations[#document.operations + 1] = operation end
                                    elseif composition.kind == "toml_insert" then
                                        document.operations[#document.operations + 1] = {kind = composition.append_text and "append" or "insert", path = composition.path}
                                    elseif render.format == "text" then return nil, "text options cannot replace an ambient copy" end
                                end
                                local parsed: unknown = nil
                                if source.content == "" then parsed = {}
                                elseif render.format == "json" then parsed = json.decode(source.content)
                                elseif render.format == "toml" then parsed = toml.decode(source.content)
                                else document.text = source.content end
                                if render.format ~= "text" then
                                    local object = bounds.object(parsed)
                                    if not object then return nil, "OptionSpec base configuration cannot be decoded" end
                                    document.value = object
                                end
                                document.source = source
                            end
                        end
                        documents[path] = document
                    end
                    if document.format ~= render.format then return nil, "OptionSpecs disagree on configuration format" end
                    local rendered_value = token_value(render, value, values)
                    if rendered_value == nil then return nil, "OptionSpec render value is unavailable" end
                    if render.format == "text" then
                        if #keys > 0 or type(rendered_value) ~= "string" then return nil, "text config render requires text and an empty path" end
                        document.text = render.merge == "append" and document.text and (document.text .. "\n\n" .. rendered_value) or rendered_value
                    else
                        if #keys == 0 then return nil, "structured config render requires a path" end
                        local err = assign(document.value, keys, rendered_value, render.merge == "append")
                        if err then return nil, err end
                        local found = false
                        for _, operation in ipairs(document.operations) do
                            if canonical.encode(operation.path) == canonical.encode(keys) then
                                operation.kind = render.merge == "append" and "append" or "set"; found = true
                            end
                        end
                        if not found then document.operations[#document.operations + 1] = {kind = render.merge == "append" and "append" or "set", path = keys} end
                    end
                end
            end
        end
    end
    local result: {configuration.Configuration} = {}
    for _, file in ipairs(files) do if not documents[file.path] then result[#result + 1] = file end end
    local paths: {string} = {}
    for path in pairs(documents) do paths[#paths + 1] = path end
    table.sort(paths, function(left: string, right: string): boolean
        local a, b = documents[left].format == "text", documents[right].format == "text"
        if a ~= b then return not a end
        return left < right
    end)
    local ordered: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, file in ipairs(files) do
        if documents[file.path] and not seen[file.path] then ordered[#ordered + 1] = file.path; seen[file.path] = true end
    end
    for _, path in ipairs(paths) do if not seen[path] then ordered[#ordered + 1] = path end end
    for _, path in ipairs(ordered) do
        local document = documents[path]
        local content: string? = document.text
        if document.format == "json" then content = canonical.encode(document.value)
        elseif document.format == "toml" then content = toml.encode(document.value) end
        if not content or #content > configuration.MAX_CONFIGURATION_BYTES then return nil, "OptionSpec configuration exceeds encoding bound" end
        local digest = hash.sha256(content)
        if not digest then return nil, "OptionSpec configuration digest unavailable" end
        local source = document.source
        local composition: configuration.Composition? = nil
        if document.base_path then
            composition = {kind = document.format == "toml" and "toml_patch" or "json_patch", base_path = document.base_path, operations = document.operations}
        end
        result[#result + 1] = {composition = composition, revision = "bee.option-config@1", path = path, content = content, digest = digest,
            provider_ref = source and source.provider_ref ~= configuration.LOGIN_PROVIDER_REF and source.provider_ref or configuration.OPTIONS_PROVIDER_REF,
            secret_fields = source and source.secret_fields}
    end
    return result, nil
end

function M.environment(fields: Object, values: Object, context: string): ({[string]: string}?, string?)
    local result: {[string]: string} = {}
    local seen: {[string]: boolean} = {}
    for name, raw in pairs(fields) do
        local declaration = bounds.object(raw)
        local renders = declaration and bounds.array(declaration.render, 8)
        local value = values[name]
        if value ~= nil and renders then
            for _, raw_render in ipairs(renders) do
                local render = bounds.object(raw_render)
                local contexts = render and bounds.ids(render.contexts, true)
                if render and render.kind == "env" and contexts and bounds.member(context, contexts) then
                    local rendered_value = token_value(render, value, values)
                    local environment_value = bounds.object(rendered_value)
                    if environment_value and environment_value.kind == "literal" then rendered_value = environment_value.value end
                    local destination = bounds.line(render.name, 128)
                    if environment_value and environment_value.kind == "credential" then
                        if not destination or seen[destination] or not bounds.id(environment_value.credential_ref) then return nil, "OptionSpec credential environment is invalid" end
                        seen[destination] = true
                    else
                    if not destination or seen[destination] or (type(rendered_value) ~= "string" and type(rendered_value) ~= "number" and type(rendered_value) ~= "boolean") then
                        return nil, "OptionSpec environment requires a unique name and scalar value"
                    end
                    seen[destination] = true
                    result[destination] = tostring(rendered_value)
                    end
                end
            end
        end
    end
    return result, nil
end
return M
