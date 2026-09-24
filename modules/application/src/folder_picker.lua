-- MIT. A folder picker over the roots the host admits: the roots first, then
-- one page of a folder's folders at a time through the workspace catalog's
-- roots and folders operations, and its table on the application frame.
-- The model is pure: it names the owner call to make and applies its reply.
-- Names and root references go back to the owner exactly as it sent them, so
-- any that is not a plain identifier or folder name is dropped.
local text = require("text")
local caller = require("caller")
local frame = require("frame")

type Root = {root_ref: string, access: string}
type Folder = {name: string, workspace_id: string?}
type Intent = {target: string, request: {[string]: unknown}}
-- held names the workspace that holds the folder shown, when one does.
type Picker = {roots: {Root}, root: Root?, path: string, held: string?, folders: {Folder}, cursor: string?,
    next_after: string?, back: {string}, selected: integer, error: string?}
type Object = {[string]: unknown}

local M = {}
M.PAGE = 50
M.CATALOG = "bee.workspace.catalog:"
M.NAME_LIMIT = 255
M.PATH_LIMIT = 512
local FIRST_PAGE = ""

function M.new(): Picker
    return {roots = {}, root = nil, path = "", held = nil, folders = {}, cursor = nil, next_after = nil, back = {}, selected = 1, error = nil}
end

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    return value :: Object
end

local function failure(reply: caller.Reply): string
    local fault = reply.error
    if not fault then return "The owner did not answer" end
    return text.bound(fault.code .. ": " .. fault.message, 200)
end

local function identifier(value: unknown): string?
    if type(value) ~= "string" or value == "" or #value > 160 or value:find("[%c/]") then return nil end
    return value
end

-- One folder name: no separator, no control character, never "." or "..".
function M.name(value: unknown): string?
    if type(value) ~= "string" or value == "" or value == "." or value == ".." or #value > M.NAME_LIMIT
        or value:find("[%c/\\]") then return nil end
    return value
end

local function workspace(value: unknown): string?
    if type(value) ~= "string" or #value ~= 32 or value:find("[^0-9a-f]") then return nil end
    return value
end

function M.join(path: string, child: string): string
    if path == "" then return child end
    return path .. "/" .. child
end

function M.writable(picker: Picker): boolean
    local root = picker.root
    return root ~= nil and root.access == "write"
end

-- Where the picker stands, for people: the root and the folder inside it.
function M.location(picker: Picker): string
    local root = picker.root
    if not root then return "" end
    if picker.path == "" then return root.root_ref end
    return root.root_ref .. "/" .. picker.path
end

function M.roots_intent(): Intent
    return {target = M.CATALOG .. "roots", request = {}}
end

function M.apply_roots(picker: Picker, reply: caller.Reply)
    local value = object(reply.value)
    if not reply.ok or not value then
        picker.error = failure(reply)
        return
    end
    local roots: {Root} = {}
    local listed = object(value.roots)
    if listed then
        for _, entry in ipairs(listed :: {unknown}) do
            local root = object(entry)
            local ref = root and identifier(root.root_ref) or nil
            local access = root and root.access or nil
            if ref and (access == "read" or access == "write") and #roots < M.PAGE then
                roots[#roots + 1] = {root_ref = ref, access = access :: string}
            end
        end
    end
    picker.roots, picker.error, picker.selected = roots, nil, 1
end

-- The page of folders the picker points at; nil while it lists the roots.
function M.folders_intent(picker: Picker): Intent?
    local root = picker.root
    if not root then return nil end
    local request: Object = {root_ref = root.root_ref, path = picker.path, limit = M.PAGE}
    if picker.cursor then request.after = picker.cursor end
    return {target = M.CATALOG .. "folders", request = request}
end

-- An answer for another root or folder than the one shown is ignored.
function M.apply_folders(picker: Picker, reply: caller.Reply)
    local root = picker.root
    if not root then return end
    local value = object(reply.value)
    if not reply.ok or not value then
        picker.error = failure(reply)
        return
    end
    if value.root_ref ~= root.root_ref or value.path ~= picker.path then return end
    local folders: {Folder} = {}
    local listed = object(value.folders)
    if listed then
        for _, entry in ipairs(listed :: {unknown}) do
            local folder = object(entry)
            local folder_name = folder and M.name(folder.name) or nil
            if folder and folder_name and #folders < M.PAGE and #M.join(picker.path, folder_name) <= M.PATH_LIMIT then
                folders[#folders + 1] = {name = folder_name, workspace_id = workspace(folder.workspace_id)}
            end
        end
    end
    picker.folders, picker.error, picker.selected = folders, nil, 1
    picker.held = workspace(value.workspace_id)
    picker.next_after = M.name(value.next_after)
end

local function reset(picker: Picker)
    picker.folders, picker.cursor, picker.next_after, picker.back, picker.selected, picker.held, picker.error = {}, nil, nil, {}, 1, nil, nil
end

function M.forward(picker: Picker): boolean
    if not picker.root or not picker.next_after then return false end
    picker.back[#picker.back + 1] = picker.cursor or FIRST_PAGE
    picker.cursor = picker.next_after
    picker.selected = 1
    return true
end

function M.backward(picker: Picker): boolean
    if not picker.root or #picker.back == 0 then return false end
    local previous = table.remove(picker.back)
    picker.cursor = previous ~= FIRST_PAGE and previous or nil
    picker.selected = 1
    return true
end

-- Moving past either end of a page of folders asks for the neighbouring page.
function M.move(picker: Picker, step: integer): string?
    local count = picker.root and #picker.folders or #picker.roots
    local selected = picker.selected + step
    if selected < 1 then return M.backward(picker) and "page" or nil end
    if selected > count then return M.forward(picker) and "page" or nil end
    picker.selected = selected
    return "select"
end

function M.select(picker: Picker, index: integer)
    local count = picker.root and #picker.folders or #picker.roots
    if index >= 1 and index <= count then picker.selected = index end
end

-- Enter opens the selected root, or the selected folder of the one shown.
-- True when the picker now needs that folder's first page.
function M.open(picker: Picker): boolean
    if not picker.root then
        local root = picker.roots[picker.selected]
        if not root then return false end
        picker.root, picker.path = root, ""
        reset(picker)
        return true
    end
    local folder = picker.folders[picker.selected]
    if not folder then return false end
    picker.path = M.join(picker.path, folder.name)
    reset(picker)
    return true
end

-- Up leaves the folder shown for its parent, and a root's top for the list
-- of roots. True when the picker now needs the parent's first page.
function M.up(picker: Picker): boolean
    if not picker.root then return false end
    if picker.path == "" then
        local left = picker.root
        picker.root = nil
        reset(picker)
        for index, root in ipairs(picker.roots) do
            if left and root.root_ref == left.root_ref then picker.selected = index end
        end
        return false
    end
    picker.path = picker.path:match("^(.*)/[^/]+$") or ""
    reset(picker)
    return true
end

-- The roots, then one page of the folders inside the folder shown, each
-- marked when a workspace holds it. use_hint names the key that takes the
-- folder shown.
function M.draw(painter: frame.Painter, rect: frame.Rect, picker: Picker, offset: integer, use_hint: string): frame.Window
    if picker.error then
        frame.empty(painter, rect.y, picker.root and "Could not read the folders" or "Could not read the admitted roots", picker.error, rect)
        return {offset = 0, capacity = 0}
    end
    local cells: {{string}} = {}
    local keys: {string} = {}
    local columns: {frame.Column}
    if not picker.root then
        if #picker.roots == 0 then
            frame.empty(painter, rect.y, "No roots are admitted", "Esc cancel", rect)
            return {offset = 0, capacity = 0}
        end
        for index, root in ipairs(picker.roots) do
            cells[index] = {root.root_ref, root.access == "write" and "write" or "read"}
            keys[index] = root.root_ref
        end
        columns = {{title = "Root", width = 0}, {title = "Access", width = 6}}
    else
        if #picker.folders == 0 then
            frame.empty(painter, rect.y, "No folders inside " .. M.location(picker), use_hint .. " · ⌫ up", rect)
            return {offset = 0, capacity = 0}
        end
        for index, folder in ipairs(picker.folders) do
            cells[index] = {folder.name, folder.workspace_id and "workspace" or ""}
            keys[index] = folder.name
        end
        columns = {{title = "Folder", width = 0}, {title = "Holds", width = 9}}
    end
    if rect.width < 40 then
        for index, row in ipairs(cells) do cells[index] = {row[1]} end
        columns = {columns[1]}
    end
    return frame.table(painter, rect.y, rect.y + rect.height - 1, {columns = columns, cells = cells, keys = keys, kind = "folder",
        selected = picker.selected, offset = offset, focused = true, area = rect})
end

return M
