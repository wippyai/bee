-- MIT. Validation of CLI descriptor argv templates, their field and flag references, and the flag graph.
local bounds = require("bounds")
local shape = require("shape")
local M = {}
type Object = {[string]: unknown}
M.MAX_TEMPLATE_ITEMS = 128
M.MAX_TEMPLATE_DEPTH = 8
local object, sequence = shape.object, shape.sequence

local function validate_template(value: unknown, label: string, depth: integer): string?
    if depth > M.MAX_TEMPLATE_DEPTH then return label .. " exceeds the template nesting bound" end
    if type(value) == "string" then return nil end
    if type(value) ~= "table" then return label .. " contains an invalid template node" end
    local item = value
    local fields = bounds.fields(item, {"field", "format", "if", "if_any", "if_none", "equals", "not_equals", "starts_with", "then", "else", "option", "join", "each", "render", "context", "encoding"})
    if fields then return label .. ": " .. fields end
    local selected = 0
    for _, name in ipairs({"field", "format", "if", "if_any", "if_none", "option", "join", "each", "render"}) do if item[name] ~= nil then selected = selected + 1 end end
    if selected ~= 1 then return label .. " must select one template operation" end
    if item.render ~= nil then
        if not bounds.id(item.render) or not bounds.member(item.context, {"window", "first_turn", "resume"}) or bounds.fields(item, {"render", "context"}) then return label .. " render reference is invalid" end
        return nil
    end
    if item.field ~= nil then
        if not bounds.id(item.field) or bounds.fields(item, {"field", "encoding"}) then return label .. " field reference is malformed" end
        if item.encoding ~= nil and not bounds.member(item.encoding, {"json"}) then return label .. " field encoding is invalid" end
        return nil
    end
    if item.format ~= nil then
        if type(item.format) ~= "string" or item.format == "" or bounds.fields(item, {"format"}) then return label .. " format is malformed" end
        return nil
    end
    if item.option ~= nil then
        if item.option ~= "permission" or bounds.fields(item, {"option"}) then return label .. " option reference is malformed" end
        return nil
    end
    if item.each ~= nil then
        local each = bounds.object(item.each)
        if not each or bounds.fields(each, {"field", "flag"}) or not bounds.id(each.field)
            or (each.flag ~= nil and (not bounds.line(each.flag, 128) or tostring(each.flag):sub(1, 1) ~= "-")) then return label .. " repeated field is malformed" end
        return nil
    end
    if item.join ~= nil then
        local join, join_error = object(item.join, label .. " join")
        if not join then return join_error end
        local extra = bounds.fields(join, {"field", "separator", "prefix", "suffix", "always", "exclude"})
        if extra then return label .. " join: " .. extra end
        if not bounds.id(join.field) or type(join.separator) ~= "string" then return label .. " join is malformed" end
        for _, name in ipairs({"always", "exclude"}) do
            if join[name] ~= nil then
                local values, values_error = sequence(join[name], label .. " join." .. name, 32)
                if not values then return values_error end
                for _, entry in ipairs(values) do if not bounds.text(entry, 128) then return label .. " join." .. name .. " contains invalid text" end end
            end
        end
        for _, name in ipairs({"prefix", "suffix"}) do
            if join[name] ~= nil and type(join[name]) ~= "string" then return label .. " join." .. name .. " must be text" end
        end
        return nil
    end
    if item["if"] == nil then
        local condition_fields = item.if_any or item.if_none
        local names, names_error = sequence(condition_fields, label .. " condition fields", 16)
        if not names or #names == 0 then return names_error or (label .. " condition fields are empty") end
        for _, name in ipairs(names) do if not bounds.id(name) then return label .. " condition field is invalid" end end
    elseif not bounds.id(item["if"]) then return label .. " condition field is invalid" end
    if item.starts_with ~= nil and type(item.starts_with) ~= "string" then return label .. " starts_with must be text" end
    local branches = 0
    for _, name in ipairs({"equals", "not_equals", "starts_with"}) do if item[name] ~= nil then branches = branches + 1 end end
    if item.not_equals ~= nil and item.equals ~= nil or branches > 1 then return label .. " has conflicting condition operators" end
    local then_items, then_error = sequence(item["then"], label .. ".then", M.MAX_TEMPLATE_ITEMS)
    if not then_items then return then_error end
    if item["else"] ~= nil then
        local else_items, else_error = sequence(item["else"], label .. ".else", M.MAX_TEMPLATE_ITEMS)
        if not else_items then return else_error end
        for index, child in ipairs(else_items) do
            local child_error = validate_template(child, label .. ".else[" .. tostring(index) .. "]", depth + 1)
            if child_error then return child_error end
        end
    end
    for index, child in ipairs(then_items) do
        local child_error = validate_template(child, label .. ".then[" .. tostring(index) .. "]", depth + 1)
        if child_error then return child_error end
    end
    return nil
end

local function validate_template_record(value: unknown, label: string): string?
    local item, object_error = object(value, label)
    if not item then return object_error end
    local extra = bounds.fields(item, {"argv", "stdin", "stdin_json", "stdin_when_any", "stdin_eof", "session_end", "readiness", "provider_home_private", "login"})
    if extra then return label .. ": " .. extra end
    local argv, argv_error = sequence(item.argv, label .. ".argv", M.MAX_TEMPLATE_ITEMS)
    if not argv then return argv_error end
    for index, token in ipairs(argv) do
        local token_error = validate_template(token, label .. ".argv[" .. tostring(index) .. "]", 0)
        if token_error then return token_error end
    end
    if item.stdin ~= nil then
        local stdin_error = validate_template(item.stdin, label .. ".stdin", 0)
        if stdin_error then return stdin_error end
    end
    if item.stdin_json ~= nil and type(item.stdin_json) ~= "table" then return label .. ".stdin_json must be an object or array" end
    if item.stdin_when_any ~= nil then
        local conditions, condition_error = sequence(item.stdin_when_any, label .. ".stdin_when_any", 8)
        if not conditions or #conditions == 0 then return condition_error or (label .. ".stdin_when_any is empty") end
        for _, field in ipairs(conditions) do if not bounds.id(field) then return label .. ".stdin_when_any has an invalid field" end end
    end
    if item.stdin_eof ~= nil and type(item.stdin_eof) ~= "boolean" then return label .. ".stdin_eof must be boolean" end
    if item.provider_home_private ~= nil and type(item.provider_home_private) ~= "boolean" then return label .. ".provider_home_private must be boolean" end
    if item.login ~= nil and type(item.login) ~= "boolean" then return label .. ".login must be boolean" end
    if not bounds.id(item.readiness) then return label .. ".readiness must name how the launch reports readiness" end
    if item.session_end ~= nil and not bounds.text(item.session_end, 128) then return label .. ".session_end must be bounded text" end
    return nil
end

local function check_reference(value: unknown, fields: Object, label: string): string?
    local name = bounds.id(value)
    if not name then return label .. " is not an identifier" end
    local short = name:match("^provider%.options%.(.+)$") or name:match("^provider%.(.+)$") or name
    if fields[short] ~= true then return label .. " names undeclared field " .. name end
    return nil
end

local function check_format_references(value: string, fields: Object, label: string): string?
    for name in value:gmatch("{([^{}]+)}") do
        local reference_error = check_reference(name, fields, label .. " placeholder")
        if reference_error then return reference_error end
    end
    local unparsed = value:gsub("{[A-Za-z_][A-Za-z0-9_]*}", "")
    if unparsed:find("[{}]") then return label .. " contains a malformed field placeholder" end
    return nil
end

local function validate_template_references(value: unknown, label: string, fields: Object, flags: Object, depth: integer): string?
    if depth > M.MAX_TEMPLATE_DEPTH then return label .. " exceeds the reference nesting bound" end
    if type(value) ~= "table" then return nil end
    local item = bounds.object(value)
    if not item then
        local values, values_error = sequence(value, label, M.MAX_TEMPLATE_ITEMS)
        if not values then return values_error end
        for index, child in ipairs(values) do
            local child_error = validate_template_references(child, label .. "[" .. tostring(index) .. "]", fields, flags, depth + 1)
            if child_error then return child_error end
        end
        return nil
    end
    if item.render ~= nil then
        local reference_error = check_reference(item.render, fields, label .. ".render")
        if reference_error then return reference_error end
    end
    if item.each ~= nil then
        local each = bounds.object(item.each) or {}
        local reference_error = check_reference(each.field, fields, label .. ".each.field")
        if reference_error then return reference_error end
    end
    if item.field ~= nil then
        local reference_error = check_reference(item.field, fields, label .. ".field")
        if reference_error then return reference_error end
    end
    if item["if"] ~= nil then
        local reference_error = check_reference(item["if"], fields, label .. ".if")
        if reference_error then return reference_error end
    end
    for _, name in ipairs({"if_any", "if_none"}) do
        if item[name] ~= nil then
            local names, names_error = sequence(item[name], label .. "." .. name, 16)
            if not names then return names_error end
            for _, candidate in ipairs(names) do
                local reference_error = check_reference(candidate, fields, label .. "." .. name)
                if reference_error then return reference_error end
            end
        end
    end
    if item.format ~= nil then
        local format = bounds.text(item.format, 256)
        if not format then return label .. ".format is invalid" end
        local format_error = check_format_references(format, fields, label .. ".format")
        if format_error then return format_error end
    end
    if item.option ~= nil then
        local option = bounds.id(item.option)
        if not option or flags[option] == nil then return label .. ".option names an undeclared flag" end
    end
    if item.join ~= nil then
        local join = bounds.object(item.join)
        if not join then return label .. ".join is malformed" end
        local join_error = check_reference(join.field, fields, label .. ".join.field")
        if join_error then return join_error end
    end
    for _, name in ipairs({"then", "else"}) do
        if item[name] ~= nil then
            local branch_error = validate_template_references(item[name], label .. "." .. name, fields, flags, depth + 1)
            if branch_error then return branch_error end
        end
    end
    return nil
end

local function validate_json_references(value: unknown, label: string, fields: Object, depth: integer): string?
    if depth > M.MAX_TEMPLATE_DEPTH then return label .. " exceeds the JSON template nesting bound" end
    if type(value) ~= "table" then return nil end
    local item = bounds.object(value)
    if item and item.field ~= nil then
        if bounds.fields(item, {"field"}) then return label .. " field template is malformed" end
        return check_reference(item.field, fields, label .. ".field")
    end
    for key, child in pairs(value) do
        local child_error = validate_json_references(child, label .. "." .. tostring(key), fields, depth + 1)
        if child_error then return child_error end
    end
    return nil
end

local function flag_options(value: unknown, output: {[string]: boolean}, depth: integer): string?
    if depth > M.MAX_TEMPLATE_DEPTH or type(value) ~= "table" then return nil end
    local item = bounds.object(value)
    if item then
        if item.option ~= nil then
            local option = bounds.id(item.option)
            if not option then return "CLI descriptor flag option reference is malformed" end
            output[option] = true
        end
        for _, name in ipairs({"then", "else"}) do
            if item[name] ~= nil then
                local branch_error = flag_options(item[name], output, depth + 1)
                if branch_error then return branch_error end
            end
        end
    else
        for _, child in ipairs(value) do
            local child_error = flag_options(child, output, depth + 1)
            if child_error then return child_error end
        end
    end
    return nil
end

local function validate_flag_graph(flags: Object): string?
    local visiting: {[string]: boolean} = {}
    local visited: {[string]: boolean} = {}
    local function visit(name: string): string?
        if visiting[name] then return "CLI descriptor flag dependency cycle includes " .. name end
        if visited[name] then return nil end
        visiting[name] = true
        local flag = bounds.object(flags[name]) or {}
        local dependencies: {[string]: boolean} = {}
        local collect_error = flag_options(flag.argv, dependencies, 0)
        if collect_error then return collect_error end
        for dependency in pairs(dependencies) do
            if flags[dependency] == nil then return "CLI descriptor flag " .. name .. " references an undeclared flag " .. dependency end
            local dependency_error = visit(dependency)
            if dependency_error then return dependency_error end
        end
        visiting[name] = nil
        visited[name] = true
        return nil
    end
    for name in pairs(flags) do
        local cycle_error = visit(name)
        if cycle_error then return cycle_error end
    end
    return nil
end

M.validate_template = validate_template
M.validate_template_record = validate_template_record
M.check_reference = check_reference
M.check_format_references = check_format_references
M.validate_template_references = validate_template_references
M.validate_json_references = validate_json_references
M.validate_flag_graph = validate_flag_graph
return M
