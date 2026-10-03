-- MIT. Receipt-owned evidence for independently managed service transitions.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local M = {}
type Entry = {id: string, kind: string, meta: {[string]: unknown}, data: unknown, owner: string}
type Change = {component: string, change: string}
type Service = {id: string, owner: string, handler: string, process: string, change: string,
    before: string, candidate: string, handler_before: string, handler_candidate: string, registration_before: string, registration_candidate: string, retention: string}
type Work = {version: integer, phase: string, services: {Service}}
type CodeVisit = {entries: {[string]: boolean}, count: integer}
local function measured(raw: unknown): string?
    if type(raw) == "string" and #raw == 64 and raw:match("^[0-9a-f]+$") then return raw end
    return nil
end
local function encoded_entry(entry: Entry): (string?, string?)
    return canonical.encode({id = entry.id, kind = entry.kind, meta = entry.meta, data = entry.data}, 1048576)
end
function M.fingerprint(entry: Entry): string?
    local encoded = encoded_entry(entry)
    return encoded and hash.sha256(encoded) or nil
end
function M.entries(raw: unknown): ({Entry}?, string?)
    local value = bounds.object(raw)
    local entries = value and bounds.array(value.entries, 32768)
    if not entries then return nil, "invalid lifecycle registry entries" end
    local result: {Entry} = {}
    local seen: {[string]: boolean} = {}
    for _, item in ipairs(entries) do
        local entry = bounds.object(item)
        local id, kind = entry and bounds.id(entry.id), entry and bounds.id(entry.kind)
        local owned = entry and bounds.object(entry.registry)
        local owner = owned and bounds.line(owned.owner, 160) or ""
        if not entry or not id or not kind or not owner or seen[id] then return nil, "invalid lifecycle entry" end
        result[#result + 1] = {id = id, kind = kind, meta = bounds.object(entry.meta) or {}, data = entry.data, owner = owner}
        seen[id] = true
    end
    return result, nil
end
function M.decode(raw: unknown): Work?
    local value = bounds.object(raw)
    if not value or bounds.fields(value, {"version", "phase", "services"}) or value.version ~= 1 then return nil end
    local phase = bounds.member(value.phase, {"prepared", "quiesced", "published", "ready"})
    local entries = bounds.dense_list(value.services, 128, "lifecycle services")
    if not phase or not entries then return nil end
    local services: {Service} = {}
    local seen: {[string]: boolean} = {}
    for _, raw_entry in ipairs(entries) do
        local entry = bounds.object(raw_entry)
        if not entry or bounds.fields(entry, {"id", "owner", "handler", "process", "change", "before", "candidate", "handler_before", "handler_candidate", "registration_before", "registration_candidate", "retention"}) then return nil end
        local id, owner = bounds.id(entry.id), bounds.line(entry.owner, 160)
        local handler, process = bounds.id(entry.handler), bounds.id(entry.process)
        local change = bounds.member(entry.change, {"install", "update", "remove"})
        local before, candidate = bounds.text(entry.before, 64), bounds.text(entry.candidate, 64)
        local handler_before, handler_candidate = bounds.text(entry.handler_before, 64), bounds.text(entry.handler_candidate, 64)
        local registration_before, registration_candidate = bounds.text(entry.registration_before, 64), bounds.text(entry.registration_candidate, 64)
        if not id or not owner or not handler or not process or not change or not before or not candidate
            or not handler_before or not handler_candidate or not registration_before or not registration_candidate or entry.retention ~= "retain" or seen[id] then return nil end
        if change ~= "install" and (not measured(before) or not measured(handler_before)) then return nil end
        if change ~= "remove" and (not measured(candidate) or not measured(handler_candidate)) then return nil end
        if change == "install" and (before ~= "" or handler_before ~= "") then return nil end
        if change == "remove" and (candidate ~= "" or handler_candidate ~= "") then return nil end
        if (registration_before ~= "" and not measured(registration_before)) or (registration_candidate ~= "" and not measured(registration_candidate)) then return nil end
        if change ~= "install" and registration_before == "" then return nil end
        if change ~= "remove" and registration_candidate == "" then return nil end
        services[#services + 1] = {id = id, owner = owner, handler = handler, process = process, change = change,
            before = before, candidate = candidate, handler_before = handler_before, handler_candidate = handler_candidate, registration_before = registration_before, registration_candidate = registration_candidate, retention = "retain"}
        seen[id] = true
    end
    return {version = 1, phase = phase, services = services}
end
function M.withdrawn(raw: unknown): {[string]: boolean}
    local state = bounds.object(raw)
    local entries = state and bounds.array(state.entries, 32768)
    if not entries then error("component removal fence is unavailable") end
    local removed: {[string]: boolean} = {}
    for _, raw_entry in ipairs(entries) do
        local entry = bounds.object(raw_entry)
        local id = entry and bounds.id(entry.id)
        local receipt = id and id:sub(1, 19) == "bee.hub.operations:" and entry and bounds.object(entry.data)
        local modules = receipt and bounds.array(receipt.expected_modules, 512)
        if receipt and modules and receipt.action == "uninstall" and receipt.state ~= "complete" and receipt.state ~= "failed" then
            for _, raw_module in ipairs(modules) do
                local module = bounds.object(raw_module)
                local owner = module and bounds.line(module.component, 160)
                if owner and module and module.change == "remove" then removed[owner] = true end
            end
        end
    end
    local result: {[string]: boolean} = {}
    for _, raw_entry in ipairs(entries) do
        local entry = bounds.object(raw_entry)
        local id = entry and bounds.id(entry.id)
        local owned = entry and bounds.object(entry.registry)
        local owner = owned and bounds.line(owned.owner, 160)
        if id and owner and removed[owner] then result[id] = true end
    end
    return result
end
local function retained_code_unchanged(id: string, before: {[string]: Entry}, after: {[string]: Entry},
    visited: CodeVisit): (boolean?, string?)
    if visited.entries[id] then return true, nil end
    if visited.count >= 1024 then return nil, "service code dependency capacity exceeded" end
    local old, candidate = before[id], after[id]
    if not old or not candidate then return false, nil end
    local old_bytes, old_error = encoded_entry(old)
    if not old_bytes then return nil, old_error end
    local new_bytes, new_error = encoded_entry(candidate)
    if not new_bytes then return nil, new_error end
    if old_bytes ~= new_bytes then return false, nil end
    visited.entries[id] = true
    visited.count = visited.count + 1
    local data = bounds.object(old.data)
    if not data then return nil, "service code definition is malformed: " .. id end
    if data.imports == nil then return true, nil end
    local imports = bounds.object(data.imports)
    if not imports then return nil, "service code imports are malformed: " .. id end
    for _, raw in pairs(imports) do
        local target = bounds.id(raw)
        if not target then return nil, "service code import is invalid: " .. id end
        local old_import, new_import = before[target], after[target]
        if not old_import or not new_import then return false, nil end
        if old_import.kind == "library.lua" or new_import.kind == "library.lua" then
            local unchanged, problem = retained_code_unchanged(target, before, after, visited)
            if unchanged ~= true then return unchanged, problem end
        end
    end
    return true, nil
end
function M.capture(raw: unknown, changes: {Change}, candidates: {Entry}): (Work?, string?)
    local entries, problem = M.entries(raw)
    if not entries then return nil, problem end
    local changed: {[string]: string} = {}
    for _, item in ipairs(changes) do if item.change ~= "keep" then changed[item.component] = item.change end end
    local before: {[string]: Entry}, after: {[string]: Entry} = {}, {}
    for _, entry in ipairs(entries) do before[entry.id] = entry; if not changed[entry.owner] then after[entry.id] = entry end end
    for _, entry in ipairs(candidates) do after[entry.id] = entry end
    local services: {Service} = {}
    local seen: {[string]: boolean} = {}
    local function select(entry: Entry): string?
        if seen[entry.id] then return nil end
        local data = bounds.object(entry.data)
        local source = data and bounds.id(data.process)
        local old_source, new_source = source and before[source], source and after[source]
        local owner = old_source and old_source.owner or new_source and new_source.owner or entry.owner
        local change = changed[owner]
        if not change then return nil end
        local previous_registration, next_registration = before[entry.id], after[entry.id]
        if change == "update" and previous_registration and next_registration then
            local old_registration, old_error = encoded_entry(previous_registration)
            if not old_registration then return old_error end
            local new_registration, new_error = encoded_entry(next_registration)
            if not new_registration then return new_error end
            if old_registration == new_registration then
                local unchanged: boolean? = true
                local code_error: string?
                if source then
                    unchanged, code_error = retained_code_unchanged(source, before, after, {entries = {}, count = 0})
                end
                if unchanged == nil then return code_error or ("cannot compare service code: " .. entry.id) end
                if unchanged then seen[entry.id] = true; return nil end
            end
        end
        if entry.kind ~= "process.service" then return "component process host needs an owner lifecycle: " .. entry.id end
        local handler = bounds.id(entry.meta.component_lifecycle)
        local replacement = after[entry.id]
        local replacement_data = replacement and bounds.object(replacement.data)
        if replacement and (replacement.meta.component_lifecycle ~= handler or not replacement_data or replacement_data.process ~= source) then
            return "service lifecycle identity changes require owner review: " .. entry.id
        end
        if not new_source and replacement then return "host service still references removed component: " .. entry.id end
        local old_handler, new_handler = handler and before[handler], handler and after[handler]
        if not source or not handler or (old_source and (not old_handler or old_handler.owner ~= owner or old_handler.kind ~= "function.lua"))
            or (new_source and (not new_handler or new_handler.owner ~= owner or new_handler.kind ~= "function.lua")) then
            return "service needs an explicit lifecycle function from its owner: " .. entry.id
        end
        if #services >= 128 then return "component services exceed lifecycle bound" end
        local before_digest = old_source and M.fingerprint(old_source) or ""
        local candidate_digest = new_source and M.fingerprint(new_source) or ""
        local handler_before = old_handler and M.fingerprint(old_handler) or ""
        local handler_candidate = new_handler and M.fingerprint(new_handler) or ""
        local registration_before = before[entry.id] and M.fingerprint(before[entry.id]) or ""
        local registration_candidate = replacement and M.fingerprint(replacement) or ""
        if not registration_before or not registration_candidate or not before_digest or not candidate_digest or not handler_before or not handler_candidate then return "cannot measure lifecycle definitions" end
        services[#services + 1] = {id = entry.id, owner = owner, handler = handler, process = source,
            change = not old_source and "install" or not new_source and "remove" or "update", before = before_digest,
            candidate = candidate_digest, handler_before = handler_before, handler_candidate = handler_candidate,
            registration_before = registration_before, registration_candidate = registration_candidate, retention = "retain"}
        seen[entry.id] = true
        return nil
    end
    for _, entry in ipairs(entries) do
        if entry.kind == "process.service" or entry.kind == "process.host" or entry.kind == "http.service" then local err = select(entry); if err then return nil, err end end
    end
    for _, entry in ipairs(candidates) do
        if entry.kind == "process.service" or entry.kind == "process.host" or entry.kind == "http.service" then local err = select(entry); if err then return nil, err end end
    end
    table.sort(services, function(a: Service, b: Service): boolean return a.id < b.id end)
    return {version = 1, phase = "prepared", services = services}, nil
end
return M
