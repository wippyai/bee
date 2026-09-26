-- MIT. Framework agent closure: resolve one agent.gen1 reference with its
-- agent.trait list, function tools and contracts from a single pinned
-- registry snapshot into a hashed launch spec closure. A CLI harness route
-- admits the closure only through check_route, which refuses every required
-- capability the driver cannot prove instead of reducing a trait to its prompt.
local hash = require("hash")
local json = require("json")
local registry = require("registry")
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
M.AGENT_TYPE = "agent.gen1"
M.TRAIT_TYPE = "agent.trait"
M.TOOL_TYPE = "tool"
-- CLI harness routes by driver id. Codex takes no model input, so a route
-- through it refuses an agent that names a model.
M.CLI_DRIVERS = {"claude", "codex", "agy", "grok", "muse"}
M.MODEL_DRIVERS = {"claude", "agy", "grok", "muse"}
M.MAX_PROMPT_BYTES = 16384
M.MAX_CONTEXT_KEYS = 16
M.MAX_CONTEXT_VALUE_BYTES = 2048
M.MAX_TUNING_KEYS = 8
M.MAX_DELEGATES = 16
-- An agent tool without owner-declared annotations is presented as
-- side-effecting, non-idempotent and open-world: the conservative reading
-- until its owner says otherwise.
M.DEFAULT_ANNOTATIONS = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = true}
type Pinned = registry.Snapshot
type Scalar = string | number | boolean
type Tool = {ref: string, digest: string, alias: string, description: string, input_schema: {[string]: unknown}, output_schema: {[string]: unknown}?, scopes: {string}, annotations: {[string]: boolean}}
type Trait = {ref: string, digest: string, title: string, prompt: string, tool_refs: {string}, context: {[string]: string},
    behavior: boolean, contracts: boolean, wrappers: boolean, hooks: boolean, options: boolean, delegates: boolean}
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
-- A required trait capability is any nonempty behavior, contract, wrapper,
-- hook, option or delegate declaration: the CLI route proves none of them.
local function required(value: unknown): boolean
    if value == nil then return false end
    if type(value) == "table" then return next(value :: {[unknown]: unknown}) ~= nil end
    return true
end
local function decode_tool(ref: string, entry: {[string]: unknown}): (Tool?, string?)
    if entry.kind ~= "function.lua" then return nil, ref .. " is not a function tool" end
    local meta = bounds.object(entry.meta)
    if not meta or meta.type ~= M.TOOL_TYPE then return nil, ref .. " is not a function tool" end
    local alias = bounds.line(meta.llm_alias, 64)
    if not alias or alias == "" or not alias:match("^[%w_.%-]+$") or alias == "session" or alias == "call_tool" then
        return nil, ref .. ": llm_alias is not an MCP name Bee admits"
    end
    local alias_name: string = alias or ""
    local description = bounds.text(meta.llm_description, 4096)
    if not description then return nil, ref .. ": llm_description must be bounded text" end
    if type(meta.input_schema) ~= "string" then return nil, ref .. ": input_schema must be a JSON object" end
    local input_schema, schema_error = json.decode(meta.input_schema)
    if schema_error or type(input_schema) ~= "table" then return nil, ref .. ": input_schema must be a JSON object" end
    local output_schema: {[string]: unknown}? = nil
    if meta.output_schema ~= nil then
        if type(meta.output_schema) ~= "string" then return nil, ref .. ": output_schema must be a JSON object" end
        local decoded, output_error = json.decode(meta.output_schema)
        if output_error or type(decoded) ~= "table" then return nil, ref .. ": output_schema must be a JSON object" end
        output_schema = decoded :: {[string]: unknown}
    end
    local mcp = bounds.object(meta.mcp == nil and {} or meta.mcp)
    if not mcp then return nil, ref .. ": mcp must be an object" end
    local mcp_field = bounds.fields(mcp, {"required_scopes", "annotations"})
    if mcp_field then return nil, ref .. ": mcp: " .. mcp_field end
    local scopes, scopes_error = refs(mcp.required_scopes, ref .. ": mcp.required_scopes")
    if not scopes then return nil, scopes_error end
    local annotations: {[string]: boolean} = {}
    if mcp.annotations ~= nil then
        local declared = bounds.object(mcp.annotations)
        if not declared then return nil, ref .. ": mcp.annotations must be an object" end
        for key, item in pairs(declared) do
            if M.DEFAULT_ANNOTATIONS[key] == nil or type(item) ~= "boolean" then
                return nil, ref .. ": mcp.annotations must be booleans from the MCP annotation set"
            end
            annotations[key] = item
        end
    else
        for key, item in pairs(M.DEFAULT_ANNOTATIONS) do annotations[key] = item end
    end
    local digest, digest_error = entry_digest(ref, entry)
    if not digest then return nil, ref .. ": " .. tostring(digest_error) end
    return {ref = ref, digest = digest, alias = alias_name, description = description, input_schema = input_schema :: {[string]: unknown},
        output_schema = output_schema, scopes = scopes, annotations = annotations}, nil
end
local function decode_trait(ref: string, entry: {[string]: unknown}): (Trait?, string?)
    if entry.kind ~= "registry.entry" then return nil, ref .. " is not an agent trait" end
    local meta = bounds.object(entry.meta)
    if not meta or meta.type ~= M.TRAIT_TYPE then return nil, ref .. " is not an agent trait" end
    local title = bounds.line(meta.title, 256)
    if not title or title == "" then return nil, ref .. ": title must be nonempty text" end
    local data = bounds.object(entry.data)
    if not data then return nil, ref .. " has no data" end
    local unknown_field = bounds.fields(data, {"prompt", "tools", "context", "options", "behavior", "contracts", "wrappers", "hooks", "delegates"})
    if unknown_field then return nil, ref .. ": " .. unknown_field end
    local prompt, prompt_error = prompt_of(data, ref)
    if not prompt then return nil, prompt_error end
    local tools, tools_error = refs(data.tools, ref .. ": tools")
    if not tools then return nil, tools_error end
    local context, context_error = context_of(data.context, ref)
    if not context then return nil, context_error end
    if data.options ~= nil and not bounds.object(data.options) then return nil, ref .. ": options must be an object" end
    local digest, digest_error = entry_digest(ref, entry)
    if not digest then return nil, ref .. ": " .. tostring(digest_error) end
    return {ref = ref, digest = digest, title = title, prompt = prompt, tool_refs = tools, context = context,
        behavior = required(data.behavior), contracts = required(data.contracts), wrappers = required(data.wrappers),
        hooks = required(data.hooks), options = required(data.options), delegates = required(data.delegates)}, nil
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
        local trait, trait_error = decode_trait(ref, trait_entry)
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
            local tool, tool_error = decode_tool(ref, tool_entry)
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
local function cli_driver(driver_id: string): boolean
    for _, known in ipairs(M.CLI_DRIVERS) do if known == driver_id then return true end end
    return false
end
local function model_driver(driver_id: string): boolean
    for _, known in ipairs(M.MODEL_DRIVERS) do if known == driver_id then return true end end
    return false
end
-- check_route: admit one resolved closure for a CLI harness route. Optional
-- tuning hints pass only when the agent owner lists them as declinable;
-- every other unrepresentable capability is refused, never dropped.
function M.check_route(closure: Closure, route: Route): (Checked?, string?, string?)
    local agent_ref, driver_id = closure.ref, route.driver_id
    if driver_id ~= "wippy" and not cli_driver(driver_id) then
        return nil, "INVALID", "driver " .. driver_id .. " is not a CLI harness route"
    end
    if driver_id ~= "wippy" then
        if #closure.memory > 0 then
            return nil, "UNSUPPORTED_CAPABILITY", "agent definition " .. agent_ref .. " requires memory the " .. driver_id .. " route cannot prove"
        end
        for _, trait in ipairs(closure.traits) do
            local field: string? = nil
            if trait.behavior then field = "behavior"
            elseif trait.contracts then field = "contracts"
            elseif trait.wrappers then field = "wrappers"
            elseif trait.hooks then field = "hooks"
            elseif trait.options then field = "options"
            elseif trait.delegates then field = "delegates" end
            if field then
                return nil, "UNSUPPORTED_CAPABILITY", "agent trait " .. trait.ref .. " requires " .. field .. " the " .. driver_id .. " route cannot prove"
            end
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
        if not (model_driver(driver_id) or driver_id == "wippy") then
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
