-- MIT. Framework agent closure: resolve one agent.gen1 reference with its
-- agent.trait list, function tools and contracts from a single pinned
-- registry snapshot into a hashed launch spec closure. A CLI harness route
-- admits the closure only through check_route, which refuses every required
-- capability the driver cannot prove instead of reducing a trait to its prompt.
local hash = require("hash")
local registry = require("registry")
local bounds = require("bounds")
local canonical = require("canonical")
local driver_resolver = require("driver_resolver")
local agent_tool = require("agent_tool")
local agent_trait = require("agent_trait")
local M = {}
M.AGENT_TYPE = "agent.gen1"
M.TRAIT_TYPE = "agent.trait"
-- A CLI harness route is any driver contract.binding the host activates
-- (bee.harness.launch:harness_activation, the same list the harness catalog reads)
-- whose meta declares whether it accepts a model. No driver id is listed
-- here: an installed driver package routes the moment its binding is
-- activated and its accepts_model declaration is read.
M.DRIVER_BINDING_TYPE = "harness.driver"
M.MAX_DRIVER_BINDINGS = 64
M.MAX_PROMPT_BYTES = 16384
M.MAX_CONTEXT_KEYS = 16
M.MAX_CONTEXT_VALUE_BYTES = 2048
M.MAX_TUNING_KEYS = 8
M.MAX_DELEGATES = 16
type Pinned = registry.Snapshot
type Scalar = string | number | boolean
type Tool = agent_tool.Tool
type Trait = agent_trait.Trait
type Agent = {ref: string, digest: string, prompt: string, trait_refs: {string}, tool_refs: {string}, delegate_refs: {string},
    memory: {string}, context: {[string]: string}, model: string?, tuning: {[string]: Scalar}, declinable: {string}}
type Delegate = {ref: string, digest: string}
type Closure = {ref: string, digest: string, agent_digest: string, prompt: string, context: {[string]: string}, instructions: string,
    traits: {Trait}, tools: {Tool}, tool_names: {string}, delegates: {Delegate}, memory: {string},
    model: string?, tuning: {[string]: Scalar}, declinable: {string}}
type Route = {driver_id: string, model_map: {[string]: string}, admitted_delegates: {string}}
type Checked = {model: string?, declined: {string}}
local function digest_of(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
local function entry_digest(ref: string, entry: {[string]: unknown}): (string?, string?)
    return digest_of({id = ref, kind = entry.kind, meta = entry.meta, data = entry.data})
end
local function refs(value: unknown, label: string): ({string}?, string?)
    local ids, ids_error = bounds.ids(value == nil and {} or value, true)
    if not ids then return nil, label .. ": " .. tostring(ids_error) end
    return ids, nil
end
local function prompt_of(data: {[string]: unknown}, ref: string): (string?, string?)
    local prompt = bounds.text(data.prompt, M.MAX_PROMPT_BYTES)
    if not prompt or prompt == "" then return nil, ref .. ": prompt must be nonempty text" end
    return prompt, nil
end
local function context_of(value: unknown, ref: string): ({[string]: string}?, string?)
    local object = bounds.object(value == nil and {} or value)
    if not object then return nil, ref .. ": context must be an object" end
    local result: {[string]: string} = {}
    local count = 0
    for key, item in pairs(object) do
        count = count + 1
        if count > M.MAX_CONTEXT_KEYS then return nil, ref .. ": context exceeds " .. tostring(M.MAX_CONTEXT_KEYS) .. " keys" end
        if type(key) ~= "string" or #key == 0 or #key > 80 then return nil, ref .. ": context keys must be bounded names" end
        local text = bounds.text(item, M.MAX_CONTEXT_VALUE_BYTES)
        if not text then return nil, ref .. ": context values must be bounded text" end
        result[key] = text
    end
    return result, nil
end
local function model_of(value: unknown, ref: string): (string?, string?)
    if value == nil then return nil, nil end
    local model = bounds.text(value, 128)
    if not model or model == "" or not model:match("^[A-Za-z0-9][A-Za-z0-9._:-]*$") then
        return nil, ref .. ": model is not one bounded model identifier"
    end
    return model, nil
end
local function tuning_of(value: unknown, ref: string): ({[string]: Scalar}?, string?)
    local object = bounds.object(value == nil and {} or value)
    if not object then return nil, ref .. ": tuning must be an object" end
    local result: {[string]: Scalar} = {}
    local count = 0
    for key, item in pairs(object) do
        count = count + 1
        if count > M.MAX_TUNING_KEYS then return nil, ref .. ": tuning exceeds " .. tostring(M.MAX_TUNING_KEYS) .. " hints" end
        if type(key) ~= "string" or #key == 0 or #key > 80 or not key:match("^[a-z][a-z0-9_]*$") then
            return nil, ref .. ": tuning hints must be bounded option names"
        end
        local kind = type(item)
        if kind == "string" then
            if #item > 512 or item:find("%c") then return nil, ref .. ": tuning hint " .. key .. " must be bounded scalar text" end
        elseif kind == "number" then
            if item ~= item or item == math.huge or item == -math.huge then return nil, ref .. ": tuning hint " .. key .. " must be finite" end
        elseif kind ~= "boolean" then
            return nil, ref .. ": tuning hint " .. key .. " must be a scalar"
        end
        result[key] = item
    end
    return result, nil
end
local function decode_agent(ref: string, entry: {[string]: unknown}): (Agent?, string?)
    if entry.kind ~= "registry.entry" then return nil, ref .. " is not an agent definition" end
    local meta = bounds.object(entry.meta)
    if not meta or meta.type ~= M.AGENT_TYPE then return nil, ref .. " is not an agent definition" end
    local data = bounds.object(entry.data)
    if not data then return nil, ref .. " has no data" end
    local unknown_field = bounds.fields(data, {"prompt", "traits", "tools", "delegates", "memory", "context", "model", "tuning", "declinable"})
    if unknown_field then return nil, ref .. ": " .. unknown_field end
    local prompt, prompt_error = prompt_of(data, ref)
    if not prompt then return nil, prompt_error end
    local traits, traits_error = refs(data.traits, ref .. ": traits")
    if not traits then return nil, traits_error end
    local tools, tools_error = refs(data.tools, ref .. ": tools")
    if not tools then return nil, tools_error end
    local delegates, delegates_error = refs(data.delegates, ref .. ": delegates")
    if not delegates then return nil, delegates_error end
    if #delegates > M.MAX_DELEGATES then return nil, ref .. ": delegates exceeds " .. tostring(M.MAX_DELEGATES) .. " agents" end
    local memory, memory_error = refs(data.memory, ref .. ": memory")
    if not memory then return nil, memory_error end
    local context, context_error = context_of(data.context, ref)
    if not context then return nil, context_error end
    local model, model_error = model_of(data.model, ref)
    if model_error then return nil, model_error end
    local tuning, tuning_error = tuning_of(data.tuning, ref)
    if not tuning then return nil, tuning_error end
    local declinable, declinable_error = refs(data.declinable, ref .. ": declinable")
    if not declinable then return nil, declinable_error end
    for _, name in ipairs(declinable) do
        if tuning[name] == nil then return nil, ref .. ": declinable names " .. name .. ", which is not a tuning hint" end
    end
    local digest, digest_error = entry_digest(ref, entry)
    if not digest then return nil, ref .. ": " .. tostring(digest_error) end
    return {ref = ref, digest = digest, prompt = prompt, trait_refs = traits, tool_refs = tools, delegate_refs = delegates,
        memory = memory, context = context, model = model, tuning = tuning, declinable = declinable}, nil
end
local function read_entry(pinned: Pinned, ref: string): ({[string]: unknown}?, string?)
    if not bounds.id(ref) then return nil, "INVALID" end
    local found, err = pinned:get(ref)
    if err or type(found) ~= "table" then return nil, "NOT_FOUND" end
    local entry = bounds.object(found)
    if not entry then return nil, "INVALID" end
    return entry, nil
end
local function render_instructions(prompt: string, context: {[string]: string}): string
    local keys: {string} = {}
    for key in pairs(context) do keys[#keys + 1] = key end
    table.sort(keys)
    if #keys == 0 then return prompt end
    local lines: {string} = {}
    for _, key in ipairs(keys) do lines[#lines + 1] = key .. ": " .. context[key] end
    return prompt .. "\n\nContext:\n" .. table.concat(lines, "\n")
end
-- resolve: the hashed launch spec closure for one agent reference, read
-- entirely from the caller's pinned snapshot. Every refusal names its code.
function M.resolve(pinned: Pinned, agent_ref: string): (Closure?, string?, string?)
    local entry, entry_error = read_entry(pinned, agent_ref)
    if not entry then
        if entry_error == "INVALID" then return nil, "INVALID", "agent reference is not an identifier" end
        return nil, "NOT_FOUND", "agent definition " .. agent_ref .. " is not in the registry"
    end
    local agent, agent_error = decode_agent(agent_ref, entry)
    if not agent then return nil, "INVALID", agent_error or "invalid agent definition" end
    local traits: {Trait} = {}
    for _, ref in ipairs(agent.trait_refs) do
        local trait_entry, trait_lookup = read_entry(pinned, ref)
        if not trait_entry then
            if trait_lookup == "INVALID" then return nil, "INVALID", agent_ref .. ": trait reference is not an identifier" end
            return nil, "NOT_FOUND", "agent trait " .. ref .. " is not in the registry"
        end
        local trait, trait_error = agent_trait.registry(ref, trait_entry)
        if not trait then return nil, "INVALID", trait_error or "invalid agent trait" end
        traits[#traits + 1] = trait
    end
    local tools: {Tool} = {}
    local seen: {[string]: boolean} = {}
    local order: {string} = {}
    for _, ref in ipairs(agent.tool_refs) do order[#order + 1] = ref end
    for _, trait in ipairs(traits) do for _, ref in ipairs(trait.tool_refs) do order[#order + 1] = ref end end
    for _, ref in ipairs(order) do
        if not seen[ref] then
            seen[ref] = true
            local tool_entry, tool_lookup = read_entry(pinned, ref)
            if not tool_entry then
                if tool_lookup == "INVALID" then return nil, "INVALID", agent_ref .. ": tool reference is not an identifier" end
                return nil, "NOT_FOUND", "agent tool " .. ref .. " is not in the registry"
            end
            local tool, tool_error = agent_tool.decode(ref, tool_entry)
            if not tool then return nil, "INVALID", tool_error or "invalid agent tool" end
            tools[#tools + 1] = tool
        end
    end
    local aliases: {[string]: boolean} = {}
    for _, tool in ipairs(tools) do
        if aliases[tool.alias] then return nil, "INVALID", agent_ref .. ": tool alias " .. tool.alias .. " names two function tools" end
        aliases[tool.alias] = true
    end
    local delegates: {Delegate} = {}
    for _, ref in ipairs(agent.delegate_refs) do
        local delegate_entry, delegate_lookup = read_entry(pinned, ref)
        if not delegate_entry then
            if delegate_lookup == "INVALID" then return nil, "INVALID", agent_ref .. ": delegate reference is not an identifier" end
            return nil, "NOT_FOUND", "agent delegate " .. ref .. " is not in the registry"
        end
        local delegate, delegate_error = decode_agent(ref, delegate_entry)
        if not delegate then return nil, "INVALID", delegate_error or "invalid agent delegate" end
        delegates[#delegates + 1] = {ref = ref, digest = delegate.digest}
    end
    local parts: {string} = {agent.prompt}
    for _, trait in ipairs(traits) do parts[#parts + 1] = trait.prompt end
    local prompt = table.concat(parts, "\n\n")
    local context: {[string]: string} = {}
    for key, item in pairs(agent.context) do context[key] = item end
    for _, trait in ipairs(traits) do for key, item in pairs(trait.context) do context[key] = item end end
    local tool_digests: {string} = {}
    local trait_digests: {string} = {}
    local delegate_digests: {string} = {}
    for _, tool in ipairs(tools) do tool_digests[#tool_digests + 1] = tool.digest end
    for _, trait in ipairs(traits) do trait_digests[#trait_digests + 1] = trait.digest end
    for _, delegate in ipairs(delegates) do delegate_digests[#delegate_digests + 1] = delegate.digest end
    local digest, digest_error = digest_of({agent = agent.digest, traits = trait_digests, tools = tool_digests,
        delegates = delegate_digests, prompt = prompt, context = context, model = agent.model, tuning = agent.tuning})
    if not digest then return nil, "INVALID", agent_ref .. ": " .. tostring(digest_error) end
    -- tool_names keeps resolution order: the agent's own tools first, then
    -- each trait's tools in trait order. The order is deterministic per
    -- definition and travels unchanged into the admitted gateway tool set.
    local names: {string} = {}
    for _, tool in ipairs(tools) do names[#names + 1] = tool.alias end
    return {ref = agent_ref, digest = digest, agent_digest = agent.digest, prompt = prompt, context = context,
        instructions = render_instructions(prompt, context), traits = traits, tools = tools, tool_names = names,
        delegates = delegates, memory = agent.memory, model = agent.model, tuning = agent.tuning,
        declinable = agent.declinable}, nil, nil
end
local function native_driver(driver_id: string): boolean
    return driver_id == "wippy"
end
-- Discover one CLI harness route: the driver contract.binding is activated
-- by the host's harness_activation declaration and declares whether it
-- accepts a model. Absence of a matching activated binding is not routable;
-- a matching binding that omits accepts_model is a malformed installation.
local function resolve_cli_route(pinned: Pinned, driver_id: string): (boolean, boolean, string?)
    if driver_id == "" then return false, false, nil end
    local active, active_error = driver_resolver.active(pinned)
    if not active then return false, false, active_error end
    local found, find_error = pinned:find({[".kind"] = "contract.binding", ["meta.type"] = M.DRIVER_BINDING_TYPE})
    if find_error then return false, false, "read driver bindings for " .. driver_id end
    if not found then return false, false, nil end
    local count = 0
    for _, raw in ipairs(found) do
        count = count + 1
        if count > M.MAX_DRIVER_BINDINGS then return false, false, "more than " .. tostring(M.MAX_DRIVER_BINDINGS) .. " driver bindings" end
        local candidate = bounds.object(raw)
        if candidate and candidate.kind == "contract.binding" then
            local meta = bounds.object(candidate.meta) or {}
            if bounds.id(meta.driver_id) == driver_id then
                local ref = bounds.id(candidate.id)
                if ref and active[ref] then
                    if type(meta.accepts_model) ~= "boolean" then
                        return false, false, "driver binding " .. ref .. " does not declare accepts_model"
                    end
                    return true, meta.accepts_model, nil
                end
            end
        end
    end
    return false, false, nil
end
-- check_route: admit one resolved closure for a CLI or native harness route.
-- Optional tuning hints pass only when the agent owner lists them as
-- declinable; every other unrepresentable capability is refused, never
-- dropped. The native route proves memory by committing memory control
-- events under the attempt's fenced epoch; it proves no trait behavior,
-- contract, wrapper, hook, option or delegate capability.
function M.check_route(pinned: Pinned, closure: Closure, route: Route): (Checked?, string?, string?)
    local agent_ref, driver_id = closure.ref, route.driver_id
    local native = native_driver(driver_id)
    local cli = false
    local accepts_model = false
    if not native then
        local resolved_cli, resolved_model, resolve_error = resolve_cli_route(pinned, driver_id)
        if resolve_error then return nil, "UNAVAILABLE", resolve_error end
        cli, accepts_model = resolved_cli, resolved_model
    end
    if not native and not cli then
        return nil, "INVALID", "driver " .. driver_id .. " is not an activated CLI or native harness route"
    end
    if #closure.memory > 0 and not native then
        return nil, "UNSUPPORTED_CAPABILITY", "agent definition " .. agent_ref .. " requires memory the " .. driver_id .. " route cannot prove"
    end
    for _, trait in ipairs(closure.traits) do
        local field: string? = nil
        if trait.behavior then field = "behavior"
        elseif trait.contracts then field = "contracts"
        elseif trait.wrappers then field = "wrappers"
        elseif #trait.hooks > 0 then return nil, "UNSUPPORTED_CAPABILITY", "hooks not yet supported: " .. trait.ref
        elseif trait.options then field = "options"
        elseif trait.delegates then field = "delegates" end
        if field then
            return nil, "UNSUPPORTED_CAPABILITY", "agent trait " .. trait.ref .. " requires " .. field .. " the " .. driver_id .. " route cannot prove"
        end
    end
    local admitted: {[string]: boolean} = {}
    for _, ref in ipairs(route.admitted_delegates) do admitted[ref] = true end
    for _, delegate in ipairs(closure.delegates) do
        if not admitted[delegate.ref] then
            return nil, "FORBIDDEN", "agent delegate " .. delegate.ref .. " is not admitted by the host policy"
        end
    end
    local model: string? = nil
    if closure.model ~= nil then
        local mapped = route.model_map[closure.model]
        if not mapped then
            return nil, "UNSUPPORTED_CAPABILITY", "host policy maps no driver model for agent model " .. closure.model
        end
        if not (accepts_model or native) then
            return nil, "UNSUPPORTED_CAPABILITY", "driver " .. driver_id .. " takes no model mapping for agent model " .. closure.model
        end
        if not mapped:match("^[A-Za-z0-9][A-Za-z0-9._:-]*$") then
            return nil, "INVALID", "host policy maps agent model " .. closure.model .. " to an invalid model identifier"
        end
        model = mapped
    end
    local declined: {string} = {}
    local declinable: {[string]: boolean} = {}
    for _, name in ipairs(closure.declinable) do declinable[name] = true end
    local pending: {string} = {}
    for name in pairs(closure.tuning) do pending[#pending + 1] = name end
    table.sort(pending)
    for _, name in ipairs(pending) do
        if declinable[name] then declined[#declined + 1] = name
        else
            return nil, "UNSUPPORTED_CAPABILITY", "agent definition " .. agent_ref .. " requires tuning hint " .. name .. " the " .. driver_id .. " route cannot prove"
        end
    end
    return {model = model, declined = declined}, nil, nil
end
return M
