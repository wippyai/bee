-- MIT. The exposure catalog: which operations this node offers to the hive,
-- at which mode, and how interfaces map onto them. Metadata describes; the
-- host ceiling admits; the supervisor still checks at every admission.
local registry = require("registry")
local security = require("security")
local json = require("json")
local hash = require("hash")
local canonical = require("canonical")
local types = require("types")
local bounds = require("bounds")
local M = {}
type Limits = {max_input_bytes: integer, max_output_bytes: integer}
type Operation = {
    operation_ref: string,
    mode: types.Mode,
    revision: string,
    input_schema: {[string]: unknown},
    output_schema: {[string]: unknown},
    limits: Limits,
    measured: string,
    title: string,
}
type InterfaceKind = "tool" | "trait" | "command" | "contract_method"
type Interface = {
    interface_ref: string,
    kind: InterfaceKind,
    operation_ref: string,
    title: string,
    fixed: {[string]: unknown},
    allow: {string},
}
type Snapshot = {
    generation: integer,
    operations: {[string]: Operation},
    interfaces: {[string]: Interface},
    diagnostics: {string},
}
type ResolvedCall = {operation: Operation, input: {[string]: unknown}, input_digest: string, generation: integer}
M.INTERFACE_TYPE = "hive.interface"
local MAX_DIAGNOSTICS = 64
local function exposure_action(mode: string): string
    return "hive.expose." .. mode
end
function M.exposure_action(mode: string): string
    return exposure_action(mode)
end
-- The invocation action a principal's own scope must grant on an
-- operation; exposure publishes, invocation authorizes.
M.INVOKE = "hive.invoke"
-- A bounded object schema: explicit properties and nothing else.
local function bounded_schema(value: unknown): ({[string]: unknown}?, string?)
    local schema = bounds.object(value)
    if not schema then return nil, "schema must be an object" end
    if schema.type ~= "object" then return nil, "schema type must be object" end
    if schema.additionalProperties ~= false then return nil, "schema must set additionalProperties to false" end
    local properties = bounds.object(schema.properties)
    if not properties then return nil, "schema must declare properties" end
    for name, property in pairs(properties) do
        if not bounds.id(name) or not bounds.object(property) then return nil, "schema property " .. tostring(name) .. " is invalid" end
    end
    return schema, nil
end
local function schema_has(schema: {[string]: unknown}, name: string): boolean
    local properties = bounds.object(schema.properties)
    return properties ~= nil and properties[name] ~= nil
end
-- Reads one entry into an operation descriptor or explains why it is not one.
local function decode_operation(entry: {[string]: unknown}): (Operation?, string?)
    local entry_id = bounds.id(entry.id)
    if not entry_id then return nil, "entry id is not an identifier" end
    if entry.kind ~= "function.lua" then return nil, entry_id .. ": exposure requires a function.lua entry" end
    local meta = bounds.object(entry.meta) or {}
    local mode: unknown = meta.hive
    local supported = false
    for _, candidate in ipairs(types.MODES) do
        if candidate == mode then supported = true end
    end
    if not supported then return nil, entry_id .. ": meta.hive must be open, approval or policy" end
    local declaration = bounds.object(meta.hive_operation)
    if not declaration then return nil, entry_id .. ": meta.hive_operation is required" end
    local unknown_field = bounds.fields(declaration, {"revision", "title", "input", "output", "limits"})
    if unknown_field then return nil, entry_id .. ": " .. unknown_field end
    local revision = bounds.id(declaration.revision)
    if not revision then return nil, entry_id .. ": revision is not an identifier" end
    local title = bounds.line(declaration.title, 160)
    if not title then return nil, entry_id .. ": title must be one bounded line" end
    local input, input_error = bounded_schema(declaration.input)
    if not input then return nil, entry_id .. ": input " .. tostring(input_error) end
    local output, output_error = bounded_schema(declaration.output)
    if not output then return nil, entry_id .. ": output " .. tostring(output_error) end
    local limits: Limits = {max_input_bytes = types.MAX_INPUT_BYTES, max_output_bytes = types.MAX_OUTPUT_BYTES}
    if declaration.limits ~= nil then
        local declared = bounds.object(declaration.limits)
        if not declared then return nil, entry_id .. ": limits must be an object" end
        local unknown_limit = bounds.fields(declared, {"max_input_bytes", "max_output_bytes"})
        if unknown_limit then return nil, entry_id .. ": " .. unknown_limit end
        if declared.max_input_bytes ~= nil then
            local number = bounds.integer(declared.max_input_bytes)
            if not number or number < 1 or number > types.MAX_INPUT_BYTES then return nil, entry_id .. ": max_input_bytes must be between 1 and " .. tostring(types.MAX_INPUT_BYTES) end
            limits.max_input_bytes = number
        end
        if declared.max_output_bytes ~= nil then
            local number = bounds.integer(declared.max_output_bytes)
            if not number or number < 1 or number > types.MAX_OUTPUT_BYTES then return nil, entry_id .. ": max_output_bytes must be between 1 and " .. tostring(types.MAX_OUTPUT_BYTES) end
            limits.max_output_bytes = number
        end
    end
    local data: unknown = entry.data
    local security_config = bounds.object(data) and bounds.object((data :: {[string]: unknown}).security) or nil
    if security_config and bounds.object(security_config.actor) then
        return nil, entry_id .. ": an exposed operation cannot replace the caller's actor"
    end
    local material, encode_error = canonical.encode({kind = entry.kind, data = data, declaration = declaration, mode = mode})
    if not material then return nil, entry_id .. ": entry is not measurable: " .. tostring(encode_error) end
    local measured, hash_error = hash.sha256(material)
    if hash_error or not measured then return nil, entry_id .. ": entry is not measurable" end
    return {operation_ref = entry_id, mode = mode :: types.Mode, revision = revision, input_schema = input, output_schema = output,
        limits = limits, measured = measured, title = title}, nil
end
function M.decode_operation(entry: {[string]: unknown}): (Operation?, string?)
    return decode_operation(entry)
end
local function decode_interface(entry: {[string]: unknown}, operations: {[string]: Operation}): (Interface?, string?)
    local entry_id = bounds.id(entry.id)
    if not entry_id then return nil, "entry id is not an identifier" end
    local meta = bounds.object(entry.meta) or {}
    if meta.type ~= M.INTERFACE_TYPE then return nil, entry_id .. ": meta.type is not " .. M.INTERFACE_TYPE end
    local declaration = bounds.object(meta.hive_interface)
    if not declaration then return nil, entry_id .. ": meta.hive_interface is required" end
    local unknown_field = bounds.fields(declaration, {"kind", "operation_ref", "title", "fixed", "allow"})
    if unknown_field then return nil, entry_id .. ": " .. unknown_field end
    local kind: unknown = declaration.kind
    if kind ~= "tool" and kind ~= "trait" and kind ~= "command" and kind ~= "contract_method" then
        return nil, entry_id .. ": kind must be tool, trait, command or contract_method"
    end
    local operation_ref = bounds.id(declaration.operation_ref)
    if not operation_ref then return nil, entry_id .. ": operation_ref is not an identifier" end
    local operation = operations[operation_ref]
    if not operation then return nil, entry_id .. ": operation " .. operation_ref .. " is not in the catalog" end
    local title = bounds.line(declaration.title, 160)
    if not title then return nil, entry_id .. ": title must be one bounded line" end
    local fixed: {[string]: unknown} = {}
    if declaration.fixed ~= nil then
        local declared = bounds.object(declaration.fixed)
        if not declared then return nil, entry_id .. ": fixed must be an object" end
        for name, value in pairs(declared) do
            if not schema_has(operation.input_schema, name) then return nil, entry_id .. ": fixed argument " .. name .. " is not an operation input" end
            fixed[name] = value
        end
    end
    local allow: {string} = {}
    if declaration.allow ~= nil then
        local list, list_error = bounds.ids(declaration.allow)
        if not list then return nil, entry_id .. ": allow: " .. tostring(list_error) end
        for _, name in ipairs(list) do
            if not schema_has(operation.input_schema, name) then return nil, entry_id .. ": allowed argument " .. name .. " is not an operation input" end
            if fixed[name] ~= nil then return nil, entry_id .. ": argument " .. name .. " is both fixed and allowed" end
        end
        allow = list
    end
    return {interface_ref = entry_id, kind = kind :: InterfaceKind, operation_ref = operation_ref, title = title, fixed = fixed, allow = allow}, nil
end
function M.decode_interface(entry: {[string]: unknown}, operations: {[string]: Operation}): (Interface?, string?)
    return decode_interface(entry, operations)
end
local function note(snapshot: Snapshot, line: string)
    if #snapshot.diagnostics < MAX_DIAGNOSTICS then snapshot.diagnostics[#snapshot.diagnostics + 1] = line end
end
local function generation(): (integer?, string?)
    local version, err = registry.current_version()
    if err or not version then return nil, "read registry version" end
    local number: unknown = version:id()
    if type(number) ~= "number" then return nil, "registry version is not numeric" end
    return math.floor(number), nil
end
-- Builds the catalog under the caller's scope: only operations whose mode the
-- host ceiling admits for that entry are included.
function M.snapshot(): (Snapshot?, string?)
    local current, generation_error = generation()
    if not current then return nil, generation_error end
    local snapshot: Snapshot = {generation = current, operations = {}, interfaces = {}, diagnostics = {}}
    local functions, find_error = registry.find({[".kind"] = "function.lua"})
    if find_error or not functions then return nil, "read exposed functions" end
    for _, entry in ipairs(functions) do
        local candidate = bounds.object(entry)
        if candidate and candidate.kind == "function.lua" then
            local meta = bounds.object(candidate.meta)
            if meta and meta.hive ~= nil then
                local operation, operation_error = decode_operation(candidate)
                if not operation then
                    note(snapshot, operation_error or "invalid operation")
                elseif not security.can(exposure_action(operation.mode), operation.operation_ref) then
                    note(snapshot, operation.operation_ref .. ": host ceiling denies " .. operation.mode)
                else
                    snapshot.operations[operation.operation_ref] = operation
                end
            end
        end
    end
    local interfaces, interfaces_error = registry.find({["meta.type"] = M.INTERFACE_TYPE})
    if interfaces_error or not interfaces then return nil, "read hive interfaces" end
    for _, entry in ipairs(interfaces) do
        local candidate = bounds.object(entry)
        if candidate then
            local meta = bounds.object(candidate.meta)
            if meta and meta.type == M.INTERFACE_TYPE then
                local facade, interface_error = decode_interface(candidate, snapshot.operations)
                if not facade then
                    note(snapshot, interface_error or "invalid facade")
                else
                    snapshot.interfaces[facade.interface_ref] = facade
                end
            end
        end
    end
    return snapshot, nil
end
-- Re-reads one operation at admission time; a stale snapshot never dispatches.
function M.resolve(operation_ref: string): (Operation?, string?)
    local entry, err = registry.get(operation_ref)
    if err or not entry then return nil, "operation is not in the registry" end
    local candidate = bounds.object(entry)
    if not candidate then return nil, "operation entry is unreadable" end
    local operation, operation_error = decode_operation(candidate)
    if not operation then return nil, operation_error end
    if not security.can(exposure_action(operation.mode), operation.operation_ref) then
        return nil, operation.operation_ref .. ": host ceiling denies " .. operation.mode
    end
    return operation, nil
end
local function finish(snapshot: Snapshot, operation: Operation, input: {[string]: unknown}): (ResolvedCall?, string?)
    local schema, schema_error = canonical.encode(operation.input_schema)
    if not schema then return nil, "input schema is not encodable: " .. tostring(schema_error) end
    local valid, validation = json.validate(schema, input)
    if not valid then return nil, "input does not satisfy the operation schema: " .. tostring(validation) end
    local encoded, encode_error = canonical.encode(input)
    if not encoded then return nil, "input is not encodable: " .. tostring(encode_error) end
    if #encoded > operation.limits.max_input_bytes then return nil, "input exceeds " .. tostring(operation.limits.max_input_bytes) .. " bytes" end
    local digest, digest_error = types.digest(input)
    if not digest then return nil, digest_error end
    local resolved: ResolvedCall = {operation = operation, input = input, input_digest = digest, generation = snapshot.generation}
    return resolved, nil
end
-- Validates a direct call against the operation in this snapshot.
function M.resolve_call(snapshot: Snapshot, operation_ref: string, caller_input: unknown): (ResolvedCall?, string?)
    local operation = snapshot.operations[operation_ref]
    if not operation then return nil, "operation " .. operation_ref .. " is not exposed" end
    local input, input_error = types.decode_input(caller_input)
    if not input then return nil, input_error end
    return finish(snapshot, operation, input)
end
-- Applies an facade from the same snapshot: fixed arguments come from the
-- facade, allowed ones from the caller, nothing else.
function M.apply_interface(snapshot: Snapshot, interface_ref: string, caller_input: unknown): (ResolvedCall?, string?)
    local facade = snapshot.interfaces[interface_ref]
    if not facade then return nil, "interface " .. interface_ref .. " is not exposed" end
    local operation = snapshot.operations[facade.operation_ref]
    if not operation then return nil, "operation " .. facade.operation_ref .. " is not exposed" end
    local supplied, input_error = types.decode_input(caller_input)
    if not supplied then return nil, input_error end
    local allowed: {[string]: boolean} = {}
    for _, name in ipairs(facade.allow) do allowed[name] = true end
    local effective: {[string]: unknown} = {}
    for name, value in pairs(supplied) do
        if facade.fixed[name] ~= nil then return nil, "argument " .. name .. " is fixed by the interface" end
        if not allowed[name] then return nil, "argument " .. name .. " is not accepted by the interface" end
        effective[name] = value
    end
    for name, value in pairs(facade.fixed) do effective[name] = value end
    return finish(snapshot, operation, effective)
end
-- Public summaries for catalog.list: no schemas, no measurements, no entries
-- that are not exposed.
function M.summaries(snapshot: Snapshot): {{operation_ref: string, mode: string, revision: string, title: string}}
    local refs: {string} = {}
    for ref in pairs(snapshot.operations) do refs[#refs + 1] = ref end
    table.sort(refs)
    local result: {{operation_ref: string, mode: string, revision: string, title: string}} = {}
    for index, ref in ipairs(refs) do
        local operation = snapshot.operations[ref]
        result[index] = {operation_ref = ref, mode = operation.mode, revision = operation.revision, title = operation.title}
    end
    return result
end
return M
