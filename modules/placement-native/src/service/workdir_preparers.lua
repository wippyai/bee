-- MIT. Generic workdir-preparer extension point discovery, host authorization,
-- setup execution and cleanup execution.
local registry = require("registry")
local funcs = require("funcs")
local sql = require("sql")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local types = require("types")
local resources = require("resources")
local store = require("store")

local M = {}
type Preparer = {binding_id: string, setup: string, cleanup: string}

local function normalize(path: string): string?
    if path == "" or #path > 8192 or path:find("[%c]") then return nil end
    if path:sub(1, 1) ~= "/" then return nil end
    local parts: {string} = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then parts[#parts] = nil end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return "/" .. table.concat(parts, "/")
end

local function contains(root: string, path: string): boolean
    if root == "/" then return path:sub(1, 1) == "/" end
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function resolve_preparer(binding_ref: string): (Preparer?, string?)
    local entry, err = registry.get(binding_ref)
    if err or not entry then return nil, "preparer binding " .. binding_ref .. " is not in the registry" end
    local obj = bounds.object(entry)
    if not obj or obj.kind ~= "contract.binding" then return nil, "preparer binding " .. binding_ref .. " is not a contract binding" end
    local meta = bounds.object(obj.meta) or {}
    if meta.type ~= types.WORKDIR_PREPARER_BINDING_TYPE then
        return nil, "preparer binding " .. binding_ref .. " meta.type is not " .. types.WORKDIR_PREPARER_BINDING_TYPE
    end
    local data = bounds.object(obj.data)
    if not data then return nil, "preparer binding " .. binding_ref .. " has no data" end
    local contracts = data.contracts
    if type(contracts) ~= "table" then return nil, "preparer binding " .. binding_ref .. " has no contracts" end
    local setup_target: string? = nil
    local cleanup_target: string? = nil
    for _, raw in ipairs(contracts :: {unknown}) do
        local c = bounds.object(raw)
        if c and c.contract == types.WORKDIR_PREPARER_CONTRACT then
            local methods = bounds.object(c.methods)
            if methods then
                setup_target = bounds.id(methods.setup)
                cleanup_target = bounds.id(methods.cleanup)
            end
        end
    end
    if not setup_target or not cleanup_target then
        return nil, "preparer binding " .. binding_ref .. " does not implement " .. types.WORKDIR_PREPARER_CONTRACT
    end
    return {binding_id = binding_ref, setup = setup_target, cleanup = cleanup_target}, nil
end

function M.authorized_preparers(): ({Preparer}?, string?)
    local authorized_ids, authorized_error = resources.workdir_preparers()
    if not authorized_ids then return nil, authorized_error end
    local preparers: {Preparer} = {}
    for _, binding_ref in ipairs(authorized_ids) do
        local preparer, err = resolve_preparer(binding_ref)
        if not preparer then
            return nil, err
        end
        preparers[#preparers + 1] = preparer
    end
    return preparers, nil
end

function M.setup(db: sql.DB, request: types.LaunchRequest, attempt_id: string, initial_work_dir: string, write_roots: {string}): (string?, {string}?, string?)
    local preparers, preparers_error = M.authorized_preparers()
    if not preparers then
        local err_msg = tostring(preparers_error or "resolve workdir preparers")
        store.transition(db, attempt_id, {execution = "exited", evidence = {kind = "workdir_preparer.failed", detail = err_msg}})
        return nil, nil, err_msg
    end
    local current_work_dir = initial_work_dir
    local extra_roots: {string} = {}
    local seen_roots: {[string]: boolean} = {}

    local normalized_write_roots: {string} = {}
    for _, raw_root in ipairs(write_roots) do
        local norm = normalize(raw_root)
        if norm then normalized_write_roots[#normalized_write_roots + 1] = norm end
    end

    for _, preparer in ipairs(preparers) do
        local input = {
            attempt_id = attempt_id,
            owner_id = request.owner_id,
            workspace_id = nil,
            working_directory = current_work_dir,
            write_roots = write_roots,
            options = request.options,
            argv = request.launch.argv,
        }
        local raw, call_error = funcs.call(preparer.setup, input)
        if call_error then
            local msg = "preparer " .. preparer.binding_id .. " call failed: " .. tostring(call_error)
            store.transition(db, attempt_id, {execution = "exited", evidence = {kind = "workdir_preparer.failed", detail = msg}})
            return nil, nil, msg
        end
        local reply = bounds.object(raw)
        if not reply or reply.ok ~= true then
            local fault = reply and bounds.object(reply.error)
            local msg = fault and (tostring(fault.code) .. ": " .. tostring(fault.message)) or "preparer setup failed"
            store.transition(db, attempt_id, {execution = "exited", evidence = {kind = "workdir_preparer.failed", detail = "preparer " .. preparer.binding_id .. ": " .. msg}})
            return nil, nil, msg
        end
        local value = bounds.object(reply.value) or {}
        if value.working_directory ~= nil then
            local proposed = tostring(value.working_directory)
            local norm_workdir = normalize(proposed)
            if not norm_workdir then
                local msg = "preparer " .. preparer.binding_id .. " returned invalid working_directory"
                store.transition(db, attempt_id, {execution = "exited", evidence = {kind = "workdir_preparer.failed", detail = msg}})
                return nil, nil, msg
            end
            current_work_dir = norm_workdir
        end
        if value.extra_writable_roots ~= nil then
            local roots = bounds.array(value.extra_writable_roots, 64)
            if roots then
                for _, raw_root in ipairs(roots) do
                    local norm_root = normalize(tostring(raw_root))
                    if norm_root then
                        local allowed = false
                        for _, write_root in ipairs(normalized_write_roots) do
                            if contains(write_root, norm_root) then
                                allowed = true
                                break
                            end
                        end
                        if allowed and not seen_roots[norm_root] then
                            seen_roots[norm_root] = true
                            extra_roots[#extra_roots + 1] = norm_root
                        end
                    end
                end
            end
        end
        if value.state ~= nil then
            local state_payload = json.encode({
                binding_id = preparer.binding_id,
                cleanup = preparer.cleanup,
                state = value.state,
            })
            if state_payload then
                store.transition(db, attempt_id, {evidence = {kind = "workdir_preparer.state", detail = state_payload}})
            end
        end
        store.transition(db, attempt_id, {evidence = {kind = "workdir_preparer.setup", detail = "preparer " .. preparer.binding_id .. " completed"}})
    end
    table.sort(extra_roots)
    return current_work_dir, extra_roots, nil
end

function M.cleanup(attempt: types.Attempt): (boolean, string?)
    local db, open_error = store.open()
    if not db then return false, open_error or "open placement store" end
    local rows, query_error = db:query(
        "SELECT sequence, detail FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'workdir_preparer.state' ORDER BY sequence",
        {attempt.attempt_id}
    )
    db:release()
    if query_error then return false, "query preparer state: " .. tostring(query_error) end
    if not rows or #rows == 0 then return true, nil end

    for _, row in ipairs(rows) do
        local detail = tostring(row.detail or "")
        local decoded = json.decode(detail)
        local state_record = bounds.object(decoded)
        if state_record and state_record.cleanup and state_record.binding_id then
            local cleanup_target = tostring(state_record.cleanup)
            local binding_id = tostring(state_record.binding_id)
            local input = {
                attempt_id = attempt.attempt_id,
                owner_id = attempt.owner_id,
                state = state_record.state,
                exit = attempt.exit,
                execution_state = attempt.execution_state,
            }
            local raw, call_error = funcs.call(cleanup_target, input)
            local db_t, open_t_error = store.open()
            if not db_t then return false, open_t_error or "open placement store" end
            if call_error then
                local msg = "preparer " .. binding_id .. " cleanup call failed: " .. tostring(call_error)
                store.transition(db_t, attempt.attempt_id, {evidence = {kind = "workdir_preparer.failed", detail = msg}})
                db_t:release()
                return false, msg
            end
            local reply = bounds.object(raw)
            if not reply or reply.ok ~= true then
                local fault = reply and bounds.object(reply.error)
                local msg = fault and (tostring(fault.code) .. ": " .. tostring(fault.message)) or "cleanup failed"
                store.transition(db_t, attempt.attempt_id, {evidence = {kind = "workdir_preparer.failed", detail = "preparer " .. binding_id .. ": " .. msg}})
                db_t:release()
                return false, msg
            end
            local val = bounds.object(reply.value) or {}
            if val.retained == true then
                local reason = tostring(val.reason or "workdir retained")
                store.transition(db_t, attempt.attempt_id, {evidence = {kind = "workdir_preparer.retained", detail = "preparer " .. binding_id .. ": " .. reason}})
            else
                store.transition(db_t, attempt.attempt_id, {evidence = {kind = "workdir_preparer.cleaned", detail = "preparer " .. binding_id .. " cleaned workdir"}})
            end
            db_t:release()
        end
    end
    return true, nil
end

return M
