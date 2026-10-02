-- Read only protected bindings; app metadata cannot select its own permissions.
local registry = require("registry")
local system = require("system")
local hash = require("hash")
local contract = require("contract")
local application_admissions = require("application_admissions")
local canonical = require("canonical")
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type Entry = {id: string, kind: string, meta: Object?, data: Object}
type Follower = {observed: string?}
type Selection = {revision: string, evidence: string, bindings: {contract.Binding}, items: {contract.Descriptor}, codes: {[string]: string}?}

local function decode_entry(raw: unknown): Entry?
    local entry = bounds.object(raw)
    if not entry then return nil end
    local id, kind, data = bounds.id(entry.id), bounds.id(entry.kind), bounds.object(entry.data)
    if not id or not kind or not data then return nil end
    return {id = id, kind = kind, meta = bounds.object(entry.meta), data = data}
end

local function static_bindings(entry: Entry?): {contract.Binding}
    if not entry or entry.kind ~= "registry.entry" then error("Invalid application admission") end
    local data: unknown = entry.data
    if type(data) ~= "table" or type(data.bindings) ~= "table" then error("Invalid application admission") end
    local result: {contract.Binding} = {}
    local count = 0
    for key in pairs(data.bindings) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 64 then error("Invalid admission array") end
        count = count + 1
    end
    local seen: {[string]: boolean} = {}
    for i = 1, count do
        local binding = contract.binding(data.bindings[i])
        if not binding or seen[binding.definition_id] then error("Invalid or duplicate admission binding") end
        seen[binding.definition_id] = true; result[#result + 1] = binding
    end
    return result
end

-- Command discovery has no workspace owner. Keep its historical surface
-- limited to shipped static admission; the broker uses read(workspace_id).
function M.bindings(pinned: registry.Snapshot?): {contract.Binding}
    local entry, entry_error
    if pinned then entry, entry_error = pinned:get("bee.security:application_admission")
    else entry, entry_error = registry.get("bee.security:application_admission") end
    if entry_error or not entry then error("Invalid application admission: " .. tostring(entry_error)) end
    return static_bindings(decode_entry(entry))
end

local function descriptor(id: string, entries: {[string]: Entry}): contract.Descriptor?
    local entry = entries[id]
    if not entry or entry.kind ~= "process.lua" or type(entry.meta) ~= "table"
        or entry.meta.type ~= "bee.app" then return nil end
    return contract.descriptor(id, entry.meta.application)
end


function M.descriptor(id: string, pinned: registry.Snapshot?): contract.Descriptor?
    local entry, entry_error
    if pinned then entry, entry_error = pinned:get(id) else entry, entry_error = registry.get(id) end
    if entry_error or not entry then return nil end
    local decoded = decode_entry(entry)
    if not decoded then return nil end
    return descriptor(id, {[id] = decoded})
end

-- Execution identity includes imported Lua libraries, whose bytes are retained
-- by an already running producer even when its application revision is unchanged.
function M.code(pinned: registry.Snapshot, id: string): string
    local seen: {[string]: boolean} = {}
    local parts: {string} = {}
    local function visit(target: string): ()
        if seen[target] then return end
        seen[target] = true
        if #parts >= 1024 then error("Application code dependency capacity exceeded") end
        local entry = decode_entry(pinned:get(target))
        if not entry then error("Application code dependency is unavailable: " .. target) end
        if target ~= id and entry.kind ~= "library.lua" then return end
        local config: Object = {}
        for key, value in pairs(entry.data) do
            if key ~= "source" then config[key] = value end
        end
        local source = entry.data.source
        if type(source) ~= "string" then error("Application code source is unavailable: " .. target) end
        local encoded = assert(canonical.encode(config, 65536))
        parts[#parts + 1] = target .. ":" .. entry.kind .. ":" .. assert(hash.sha256(source)) .. ":" .. assert(hash.sha256(encoded))
        local imports = bounds.object(entry.data.imports)
        if imports then
            for _, imported in pairs(imports) do
                if type(imported) ~= "string" then error("Invalid application code import") end
                visit(imported)
            end
        end
    end
    visit(id)
    table.sort(parts)
    return assert(hash.sha256(table.concat(parts, "\n")))
end

-- Durable registry edits and activation overlay revisions both invalidate the
-- broker's admission projection. The latter does not advance registry history.
function M.revision(workspace_id: string): string
    if not contract.workspace_id(workspace_id) then error("Invalid application catalog workspace") end
    local pinned, snapshot_error = registry.snapshot()
    if not pinned or snapshot_error then error("Read application catalog snapshot: " .. tostring(snapshot_error)) end
    local version = pinned:version()
    local node_id, node_error = system.node.id()
    if not node_id or node_error then error("Node identity is unavailable: " .. tostring(node_error)) end
    local admission, admission_error = pinned:get("bee.security:application_admission")
    if not admission or admission_error or type(admission.data) ~= "table" then
        error("Read application admission revision: " .. tostring(admission_error or "invalid admission entry"))
    end
    local encoded, encode_error = canonical.encode(admission.data, 65536)
    if not encoded then error("Encode application admission revision: " .. tostring(encode_error)) end
    local fingerprint, digest_error = hash.sha256(encoded)
    if not fingerprint then error("Hash application admission revision: " .. tostring(digest_error)) end
    -- Revision discovery still invalidates malformed admission; read owns its
    -- validation and withdraws the catalog rather than retaining old authority.
    local code_fingerprint = "unavailable"
    local code_ok, observed_code = pcall(function(): string
        local codes: {string} = {}
        local selected = M.read(workspace_id, pinned)
        for definition_id, code in pairs(assert(selected.codes)) do
            codes[#codes + 1] = definition_id .. ":" .. code
        end
        table.sort(codes)
        return assert(hash.sha256(table.concat(codes, ":")))
    end)
    if code_ok then code_fingerprint = observed_code end
    return version:string() .. ":" .. fingerprint .. ":" .. code_fingerprint
        .. ":" .. application_admissions.revision(workspace_id, node_id)
end

local function items(bindings: {contract.Binding}, pinned: registry.Snapshot): {contract.Descriptor}
    local result: {contract.Descriptor} = {}
    for _, binding in ipairs(bindings) do
        local item = M.descriptor(binding.definition_id, pinned)
        if item then result[#result + 1] = item end
    end
    table.sort(result, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        if a.title ~= b.title then return a.title < b.title end
        return a.definition_id < b.definition_id
    end)
    return result
end

local function record_bindings(raw: unknown): {contract.Binding}
    if type(raw) ~= "table" then error("Invalid protected application admission bindings") end
    local count = 0
    for key in pairs(raw) do
        if type(key) ~= "number" or key ~= math.floor(key)
            or (key) < 1 or (key) > 64 then
            error("Invalid protected application admission bindings")
        end
        count = count + 1
    end
    if count == 0 then error("Invalid protected application admission bindings") end
    local result: {contract.Binding} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local binding = contract.binding((raw)[index])
        if not binding or seen[binding.definition_id] then
            error("Invalid or duplicate protected application admission binding")
        end
        seen[binding.definition_id] = true
        result[#result + 1] = binding
    end
    return result
end

-- Overlays change the effective catalog without advancing registry history.
-- Compare the bounded admission/presentation values captured in one snapshot;
-- source code and unrelated registry entries are not serialized here.
function M.read(workspace_id: string, snapshot: registry.Snapshot?): Selection
    if not contract.workspace_id(workspace_id) then error("Invalid application catalog workspace") end
    local pinned = snapshot or assert(registry.snapshot())
    local revision = pinned:version():string()
    local function lookup(id: string): Entry?
        local entry = pinned:get(id)
        return decode_entry(entry)
    end
    local node_id, node_error = system.node.id()
    if not node_id or node_error then error("Node identity is unavailable: " .. tostring(node_error)) end
    local published, publication_error = application_admissions.read(pinned, revision, workspace_id, node_id)
    if not published then error(tostring(publication_error)) end
    local bindings = static_bindings(lookup("bee.security:application_admission"))
    local seen: {[string]: boolean} = {}
    for _, binding in ipairs(bindings) do seen[binding.definition_id] = true end
    local evidence: {string} = {}
    local function consume(records: {application_admissions.Measurement}, packaged: boolean)
        for _, published_record in ipairs(records) do
            local record = published_record.record
            if record.schema_revision ~= "bee.governance-application-admission@1"
                or record.workspace_id ~= workspace_id
                or type(published_record.digest) ~= "string"
                or #published_record.digest ~= 64 or not published_record.digest:match("^[0-9a-f]+$") then
                error("Invalid protected application admission record")
            end
            local admitted = false
            for _, binding in ipairs(record_bindings(record.bindings)) do
                if packaged and seen[binding.definition_id] then
                    -- An explicitly delivered record for the same definition wins.
                else
                    if seen[binding.definition_id] then
                        error("Duplicate application admission binding: " .. binding.definition_id)
                    end
                    if #bindings >= 64 then error("Application admission capacity is exceeded") end
                    seen[binding.definition_id] = true
                    bindings[#bindings + 1] = binding
                    admitted = true
                end
            end
            if admitted then evidence[#evidence + 1] = published_record.digest end
        end
    end
    consume(published.governed, false)
    consume(published.packages, true)
    table.sort(bindings, function(left: contract.Binding, right: contract.Binding): boolean
        return left.definition_id < right.definition_id
    end)
    table.sort(evidence)
    local selected_items = items(bindings, pinned)
    local codes: {[string]: string} = {}
    for _, item in ipairs(selected_items) do codes[item.definition_id] = M.code(pinned, item.definition_id) end
    return {revision = revision, evidence = table.concat(evidence, ":"), bindings = bindings,
        items = selected_items, codes = codes}
end

local function open_target(selection: Selection?, definition_id: string): (contract.Binding?, contract.Descriptor?)
    if not selection then return nil, nil end
    local binding: contract.Binding? = nil
    for _, candidate in ipairs(selection.bindings) do
        if candidate.definition_id == definition_id then binding = candidate; break end
    end
    if not binding then return nil, nil end
    for _, item in ipairs(selection.items) do
        if item.definition_id == definition_id then return binding, item end
    end
    return binding, nil
end

-- An open can arrive while an admission write is still converging across its
-- registry entries. Refresh once more after a miss so a transient torn read
-- does not become a user-visible not-admitted refusal.
function M.resolve_open<T: Selection>(definition_id: string, refresh: () -> T?): (T?, contract.Binding?, contract.Descriptor?)
    local selected = refresh()
    local binding, descriptor = open_target(selected, definition_id)
    if binding and descriptor then return selected, binding, descriptor end
    selected = refresh()
    binding, descriptor = open_target(selected, definition_id)
    return selected, binding, descriptor
end

-- These are bounded, decoded records, not arbitrary registry data. Compare
-- values directly: JSON object field order is not a catalog revision.
function M.same(a: Selection, b: Selection): boolean
    if a.revision ~= b.revision or a.evidence ~= b.evidence
        or #a.bindings ~= #b.bindings or #a.items ~= #b.items then return false end
    for i, left in ipairs(a.bindings) do
        local right = b.bindings[i]
        if left.definition_id ~= right.definition_id or left.appearance_write ~= right.appearance_write
            or left.application_stop ~= right.application_stop
            or left.scope_management ~= right.scope_management or left.close_grace_ms ~= right.close_grace_ms
            or left.thread_access ~= right.thread_access
            or #left.policies ~= #right.policies then return false end
        for j, policy in ipairs(left.policies) do
            if policy ~= right.policies[j] then return false end
        end
    end
    for i, left in ipairs(a.items) do
        local right = b.items[i]
        if (a.codes and a.codes[left.definition_id]) ~= (b.codes and b.codes[right.definition_id])
            or left.definition_id ~= right.definition_id or left.definition_revision ~= right.definition_revision
            or left.title ~= right.title or left.icon ~= right.icon or left.group ~= right.group
            or left.role ~= right.role or left.singleton ~= right.singleton
            or left.resume_schema ~= right.resume_schema or left.restart_policy ~= right.restart_policy then return false end
    end
    return true
end
function M.replaces(running: contract.Descriptor, replacement: contract.Descriptor?, running_code: string?, replacement_code: string?): boolean
    return replacement ~= nil and (replacement.definition_revision ~= running.definition_revision
        or running_code ~= replacement_code)
end
-- A revision follower applies each observed revision through a refresh. The
-- observed revision advances only when the refresh succeeds, so a refresh that
-- read an inconsistent catalog is retried at the next check.
function M.follower(observed: string?): Follower
    return {observed = observed}
end

function M.invalidate(follower: Follower): ()
    follower.observed = nil
end

function M.follow(follower: Follower, current: string, refresh: () -> boolean): boolean
    if current == follower.observed then return false end
    if refresh() then follower.observed = current end
    return true
end

return M
