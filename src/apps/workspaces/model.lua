-- MIT. The Workspaces viewer, pure: one page of the node workspace catalog at
-- a time (never the whole list), a search that is a label prefix or, after
-- "/", a folder prefix under every admitted root, and the selected workspace
-- as its owners describe it.
-- Every value from an owner is bounded here before a view draws it.
local text = require("text")
local caller = require("caller")

type Summary = {workspace_id: string, label: string, root_ref: string, subpath: string, state: string, created_at: string,
    last_used_at: string}
type Item = {label: string, detail: string}
type Section = {title: string, items: {Item}, total: integer, error: string?}
type Detail = {workspace_id: string, live: boolean, applications: {Item}, threads: {Item}, more_threads: boolean,
    threads_error: string?, sections: {Section}, error: string?}
type Intent = {target: string, request: {[string]: unknown}}
type State = {tab: string, query: string, editing: boolean, items: {Summary}, cursor: string?, next_after: string?,
    back: {string}, page: integer, selected: string, detail: Detail?, showing: boolean, confirming: boolean,
    status: string, error: string?, served: string?}
type Object = {[string]: unknown}

local M = {}
M.PAGE = 50
M.THREADS = 10
M.CATALOG = "bee.workspace.catalog:"
M.THREAD_LIST = "bee.threads.service:list_workspace"
M.LABEL_LIMIT = 240
M.TEXT_LIMIT = 512
M.QUERY_LIMIT = 120
local FIRST_PAGE = ""

function M.new(): State
    return {tab = "active", query = "", editing = false, items = {}, cursor = nil, next_after = nil, back = {}, page = 1,
        selected = "", detail = nil, showing = false, confirming = false, status = "", error = nil, served = nil}
end

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    return value :: Object
end

local function bounded(value: unknown, limit: integer?): string
    return text.bound(value, limit or M.TEXT_LIMIT)
end

local function failure(reply: caller.Reply): string
    local fault = reply.error
    if not fault then return "The owner did not answer" end
    return bounded(fault.code .. ": " .. fault.message, 200)
end

function M.summary(value: unknown): Summary?
    local row = object(value)
    if not row or type(row.workspace_id) ~= "string" or #(row.workspace_id :: string) ~= 32 then return nil end
    return {workspace_id = row.workspace_id :: string, label = bounded(row.label, M.LABEL_LIMIT), root_ref = bounded(row.root_ref, 160),
        subpath = bounded(row.subpath), state = row.state == "archived" and "archived" or "active",
        created_at = bounded(row.created_at, 40), last_used_at = bounded(row.last_used_at, 40)}
end

function M.folder(summary: Summary): string
    if summary.subpath == "" then return summary.root_ref end
    return summary.root_ref .. "/" .. summary.subpath
end

function M.selected(state: State): Summary?
    for _, item in ipairs(state.items) do
        if item.workspace_id == state.selected then return item end
    end
    return nil
end

-- The request for the page the state points at: the catalog list, a label
-- search, or, for a query starting with "/", a folder search under every
-- root the host admits.
function M.listing(state: State): Intent
    local request: Object = {state = state.tab, limit = M.PAGE}
    if state.cursor then request.after = state.cursor end
    local query = state.query
    if query == "" then return {target = M.CATALOG .. "list", request = request} end
    if query:sub(1, 1) == "/" then
        local path = query:sub(2):gsub("/+$", "")
        request.path = path
        return {target = M.CATALOG .. "search", request = request}
    end
    request.label = query
    return {target = M.CATALOG .. "search", request = request}
end

-- A page replaces the one before it. The selection stays on its workspace
-- when the page still holds it.
function M.apply_page(state: State, reply: caller.Reply)
    local value = object(reply.value)
    if not reply.ok or not value then
        state.error = failure(reply)
        return
    end
    local items: {Summary} = {}
    local listed = object(value.items)
    if listed then
        for _, entry in ipairs(listed :: {unknown}) do
            local summary = M.summary(entry)
            if summary and #items < M.PAGE then items[#items + 1] = summary end
        end
    end
    state.items = items
    state.error = nil
    local next_after = value.next_after
    state.next_after = type(next_after) == "string" and #next_after <= 2200 and next_after or nil
    if not M.selected(state) then state.selected = items[1] and items[1].workspace_id or "" end
end

-- Paging keeps one page and the cursors that lead back to earlier ones.
function M.forward(state: State): boolean
    if not state.next_after then return false end
    state.back[#state.back + 1] = state.cursor or FIRST_PAGE
    state.cursor = state.next_after
    state.page = state.page + 1
    state.selected = ""
    return true
end

function M.backward(state: State): boolean
    if #state.back == 0 then return false end
    local previous = table.remove(state.back)
    state.cursor = previous ~= FIRST_PAGE and previous or nil
    state.page = state.page - 1
    state.selected = ""
    return true
end

local function restart(state: State)
    state.cursor, state.next_after, state.back, state.page, state.selected = nil, nil, {}, 1, ""
    state.detail, state.showing, state.confirming = nil, false, false
end

-- Moving past either end of the page asks for the neighbouring page.
function M.move(state: State, step: integer): string?
    local index = 0
    for position, item in ipairs(state.items) do
        if item.workspace_id == state.selected then index = position end
    end
    local target = index + step
    if target < 1 then return M.backward(state) and "page" or nil end
    if target > #state.items then return M.forward(state) and "page" or nil end
    state.selected = state.items[target].workspace_id
    state.confirming = false
    return "select"
end

function M.select(state: State, workspace_id: string)
    state.selected = workspace_id
    state.confirming = false
end

function M.switch(state: State, tab: string)
    if tab ~= "active" and tab ~= "archived" or tab == state.tab then return end
    state.tab = tab
    state.status = ""
    restart(state)
end

-- Typing edits the search; Enter runs it from its first page.
function M.type_text(state: State, value: string)
    if value:find("%c") or #state.query + #value > M.QUERY_LIMIT then return end
    state.query = state.query .. value
end

function M.erase(state: State)
    if state.query == "" then return end
    local cut = #state.query
    while cut > 1 do
        local byte = state.query:byte(cut)
        if byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1
    end
    state.query = state.query:sub(1, cut - 1)
end

function M.submit(state: State)
    state.editing = false
    state.status = ""
    restart(state)
end

function M.inspect_intent(state: State): Intent?
    if state.selected == "" then return nil end
    return {target = M.CATALOG .. "inspect", request = {workspace_id = state.selected}}
end

function M.threads_intent(state: State): Intent?
    if state.selected == "" then return nil end
    return {target = M.THREAD_LIST, request = {workspace_id = state.selected, limit = M.THREADS}}
end

local function items(value: unknown, label: (Object) -> string, detail: (Object) -> string, limit: integer): {Item}
    local list: {Item} = {}
    local entries = object(value)
    if not entries then return list end
    for _, entry in ipairs(entries :: {unknown}) do
        local item = object(entry)
        if item and #list < limit then list[#list + 1] = {label = bounded(label(item), M.LABEL_LIMIT), detail = bounded(detail(item))} end
    end
    return list
end

function M.apply_inspect(state: State, workspace_id: string, reply: caller.Reply)
    if workspace_id ~= state.selected then return end
    local previous = state.detail
    local detail: Detail = {workspace_id = workspace_id, live = false, applications = {}, threads = previous and previous.workspace_id == workspace_id and previous.threads or {},
        more_threads = previous and previous.workspace_id == workspace_id and previous.more_threads or false,
        threads_error = previous and previous.workspace_id == workspace_id and previous.threads_error or nil, sections = {}, error = nil}
    local value = object(reply.value)
    if not reply.ok or not value then
        detail.error = failure(reply)
        state.detail = detail
        return
    end
    detail.live = value.live == true
    detail.applications = items(value.applications, function(item: Object): string return tostring(item.definition_id) end,
        function(item: Object): string return tostring(item.instance_id) .. " · " .. tostring(item.restart_policy) end, 16)
    local extensions = object(value.extensions)
    if extensions then
        for _, entry in ipairs(extensions :: {unknown}) do
            local extension = object(entry)
            if extension and #detail.sections < 16 then
                local fault = extension.error
                detail.sections[#detail.sections + 1] = {title = bounded(extension.title, 80),
                    items = items(extension.items, function(item: Object): string return tostring(item.label) end,
                        function(item: Object): string return item.detail == nil and "" or tostring(item.detail) end, 50),
                    total = type(extension.total) == "number" and math.floor(extension.total :: number) or 0,
                    error = fault ~= nil and bounded(fault, 200) or nil}
            end
        end
    end
    state.detail = detail
end

function M.apply_threads(state: State, workspace_id: string, reply: caller.Reply)
    local detail = state.detail
    if workspace_id ~= state.selected or not detail or detail.workspace_id ~= workspace_id then return end
    local value = object(reply.value)
    if not reply.ok or not value then
        detail.threads, detail.more_threads, detail.threads_error = {}, false, failure(reply)
        return
    end
    detail.threads = items(value.threads, function(item: Object): string
        local title = tostring(item.title or "")
        return title ~= "" and title or tostring(item.thread_id)
    end, function(item: Object): string return tostring(item.state) end, M.THREADS)
    detail.more_threads = type(value.next_after_thread_id) == "string"
    detail.threads_error = nil
end

-- Archive on the active tab, restore on the archived tab. Archiving asks first.
function M.change_intent(state: State): Intent?
    local selected = M.selected(state)
    if not selected then return nil end
    local operation = state.tab == "archived" and "restore" or "archive"
    return {target = M.CATALOG .. operation, request = {workspace_id = selected.workspace_id}}
end

function M.apply_change(state: State, reply: caller.Reply)
    state.confirming = false
    local changed = M.summary(reply.value)
    if not reply.ok or not changed then
        state.status = failure(reply)
        return
    end
    state.status = (changed.state == "archived" and "Archived " or "Restored ") .. (changed.label ~= "" and changed.label or changed.workspace_id)
    local kept: {Summary} = {}
    for _, item in ipairs(state.items) do
        if item.workspace_id ~= changed.workspace_id then kept[#kept + 1] = item end
    end
    state.items = kept
    state.selected = kept[1] and kept[1].workspace_id or ""
    state.detail = nil
    state.showing = false
end

function M.edit(state: State, on: boolean) state.editing = on end
function M.confirm(state: State, on: boolean) state.confirming = on end
function M.show(state: State, on: boolean) state.showing = on end
function M.say(state: State, status: string) state.status = bounded(status, 400) end
function M.forget_detail(state: State) state.detail = nil end
-- The viewer keeps at most one workspace served while it is open.
function M.serve(state: State, workspace_id: string?) state.served = workspace_id end
function M.label(state: State, workspace_id: string): string
    for _, item in ipairs(state.items) do
        if item.workspace_id == workspace_id then return item.label ~= "" and item.label or workspace_id end
    end
    return workspace_id
end

return M
