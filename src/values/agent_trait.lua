local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local M = {}
M.EVENTS = {"session.started", "session.ended", "prompt.submitted", "tool.before", "tool.after", "turn.completed"}
M.HOOKS = {"session.start", "prompt.submit", "tool.before", "tool.after"}
type Declaration = {id: string, title: string, prompt: string, tools: {string}, listens: {string}?, hooks: {string}?, application_ref: string?, application_revision: string?, digest: string?}
type Trait = {ref: string, digest: string, title: string, prompt: string, tool_refs: {string}, context: {[string]: string},
    listens: {string}, hooks: {string}, application_ref: string?, application_revision: string?,
    behavior: boolean, contracts: boolean, wrappers: boolean, options: boolean, delegates: boolean}
function M.names(value: unknown, vocabulary: {string}, label: string): ({string}?, string?)
    local names, err = bounds.ids(value == nil and {} or value, true)
    if not names then return nil, label .. ": " .. tostring(err) end
    for _, name in ipairs(names) do
        if not bounds.member(name, vocabulary) then return nil, label .. ": unknown name " .. name end
    end
    table.sort(names)
    return names, nil
end
local function required(value: unknown): boolean
    return value ~= nil and (type(value) ~= "table" or next(value) ~= nil)
end
function M.decode(ref: string, meta: unknown, raw: unknown): (Trait?, string?)
    local metadata, data = bounds.object(meta), bounds.object(raw)
    if not metadata or not data then return nil, ref .. ": trait needs metadata and data" end
    local extra = bounds.fields(data, {"prompt", "tools", "context", "options", "behavior", "contracts", "wrappers", "listens", "hooks", "delegates"})
    if extra then return nil, ref .. ": " .. extra end
    local title, prompt = bounds.line(metadata.title, 256), bounds.text(data.prompt, 16384)
    if not title or not prompt then return nil, ref .. ": title and prompt must be bounded text" end
    local tools, tool_error = bounds.ids(data.tools == nil and {} or data.tools, true)
    if not tools or #tools > 32 then return nil, ref .. ": tools: " .. tostring(tool_error or "exceeds 32 items") end
    local context = bounds.object(data.context == nil and {} or data.context)
    if not context then return nil, ref .. ": context must be an object" end
    local copied: {[string]: string} = {}
    local count = 0
    for key, item in pairs(context) do
        count = count + 1
        local text = bounds.text(item, 2048)
        if count > 16 or #key == 0 or #key > 80 or not text then return nil, ref .. ": invalid context" end
        copied[key] = text
    end
    if data.options ~= nil and not bounds.object(data.options) then return nil, ref .. ": options must be an object" end
    local listens, listen_error = M.names(data.listens, M.EVENTS, "listens")
    if not listens then return nil, ref .. ": " .. tostring(listen_error) end
    local hooks, hook_error = M.names(data.hooks, M.HOOKS, "hooks")
    if not hooks then return nil, ref .. ": " .. tostring(hook_error) end
    local application, valid = bounds.optional_id(metadata, "application_ref")
    local revision, valid_revision = bounds.optional_id(metadata, "application_revision")
    if not valid or not valid_revision then return nil, ref .. ": invalid application identity" end
    if (#listens > 0 or #hooks > 0) and not application then return nil, ref .. ": listens and hooks require application_ref" end
    local encoded, err = canonical.encode({id = ref, meta = metadata, data = data})
    if not encoded then return nil, err end
    local digest, digest_error = hash.sha256(encoded)
    if not digest then return nil, tostring(digest_error) end
    return {ref = ref, digest = digest, title = title, prompt = prompt, tool_refs = tools, context = copied,
        listens = listens, hooks = hooks, application_ref = application, application_revision = revision,
        behavior = required(data.behavior), contracts = required(data.contracts), wrappers = required(data.wrappers),
        options = required(data.options), delegates = required(data.delegates)}, nil
end
function M.registry(ref: string, entry: {[string]: unknown}): (Trait?, string?)
    local meta = bounds.object(entry.meta)
    if entry.kind ~= "registry.entry" or not meta or meta.type ~= "agent.trait" then return nil, ref .. " is not an agent trait" end
    local trait, err = M.decode(ref, meta, entry.data)
    if trait and trait.prompt == "" then return nil, ref .. ": prompt must be nonempty text" end
    return trait, err
end
function M.declaration(raw: unknown): (Declaration?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "trait must be an object" end
    local extra = bounds.fields(value, {"id", "title", "prompt", "tools", "listens", "hooks", "application_ref", "application_revision", "digest"})
    if extra then return nil, extra end
    local id = bounds.id(value.id)
    if not id or not id:match("^[%w_.%-]+:[%w_.%-]+$") then return nil, "invalid trait reference" end
    local trait, err = M.decode(id, {title = value.title, application_ref = value.application_ref, application_revision = value.application_revision},
        {prompt = value.prompt, tools = value.tools, listens = value.listens, hooks = value.hooks})
    if not trait then return nil, err end
    return {id = id, title = trait.title, prompt = trait.prompt, tools = trait.tool_refs, listens = trait.listens, hooks = trait.hooks,
        application_ref = trait.application_ref, application_revision = trait.application_revision, digest = bounds.id(value.digest) or trait.digest}, nil
end
function M.extension(trait: Declaration): boolean
    return #(trait.listens or {}) > 0 or #(trait.hooks or {}) > 0
end
return M
