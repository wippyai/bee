-- MIT. The Workspaces create flow, pure: a folder picked from the roots the
-- host admits and one page of a folder's folders at a time, then a label and,
-- under a root admitted for writing, an optional new folder made inside the
-- chosen one. Names and root references come back to the owner exactly as it
-- sent them, so any that is not a plain identifier or folder name is dropped;
-- every other owner text is bounded.
local text = require("text")
local caller = require("caller")
local model = require("model")

type Root = {root_ref: string, access: string}
type Folder = {name: string, workspace_id: string?}
-- step: "folder" picks the root and folder, "details" names the workspace.
-- field: 1 the label, 2 the new folder.
type Form = {step: string, roots: {Root}, root: Root?, path: string, held: string?, folders: {Folder}, cursor: string?,
    next_after: string?, back: {string}, selected: integer, error: string?, field: integer, label: string, label_edited: boolean,
    new_folder: string, failure: string?}
type Object = {[string]: unknown}

local M = {}
M.PAGE = 50
M.ARGUMENT = "create"
M.CATALOG = "bee.workspace.catalog:"
M.LABEL_LIMIT = 240
M.NAME_LIMIT = 255
M.PATH_LIMIT = 512
local FIRST_PAGE = ""

function M.new(): Form
    return {step = "folder", roots = {}, root = nil, path = "", held = nil, folders = {}, cursor = nil, next_after = nil, back = {},
        selected = 1, error = nil, field = 1, label = "", label_edited = false, new_folder = "", failure = nil}
end

-- The viewer opens with the form when its launch names the create flow.
function M.requested(arguments: {string}): boolean
    return arguments[1] == M.ARGUMENT
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
local function name(value: unknown): string?
    if type(value) ~= "string" or value == "" or value == "." or value == ".." or #value > M.NAME_LIMIT
        or value:find("[%c/\\]") then return nil end
    return value
end

local function workspace(value: unknown): string?
    if type(value) ~= "string" or #value ~= 32 or value:find("[^0-9a-f]") then return nil end
    return value
end

local function join(path: string, child: string): string
    if path == "" then return child end
    return path .. "/" .. child
end

local function last(path: string): string
    return path:match("([^/]+)$") or path
end

function M.writable(form: Form): boolean
    local root = form.root
    return root ~= nil and root.access == "write"
end

-- The folder the workspace will hold: the chosen one, or the new folder
-- inside it.
local function target(form: Form): string
    if form.new_folder ~= "" and M.writable(form) then return join(form.path, form.new_folder) end
    return form.path
end

-- A label nobody typed follows the folder the workspace will hold.
local function suggest(form: Form)
    if form.label_edited then return end
    local root = form.root
    local folder = target(form)
    form.label = folder ~= "" and text.bound(last(folder), M.LABEL_LIMIT) or (root and root.root_ref or "")
end

-- Where the form stands, for people: the root and the folder inside it.
function M.location(form: Form): string
    local root = form.root
    if not root then return "" end
    if form.path == "" then return root.root_ref end
    return root.root_ref .. "/" .. form.path
end

function M.roots_intent(): model.Intent
    return {target = M.CATALOG .. "roots", request = {}}
end

function M.apply_roots(form: Form, reply: caller.Reply)
    local value = object(reply.value)
    if not reply.ok or not value then
        form.error = failure(reply)
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
    form.roots, form.error, form.selected = roots, nil, 1
end

-- The page of folders the form points at; nil while it lists the roots.
function M.folders_intent(form: Form): model.Intent?
    local root = form.root
    if not root then return nil end
    local request: Object = {root_ref = root.root_ref, path = form.path, limit = M.PAGE}
    if form.cursor then request.after = form.cursor end
    return {target = M.CATALOG .. "folders", request = request}
end

-- An answer for another root or folder than the one shown is ignored.
function M.apply_folders(form: Form, reply: caller.Reply)
    local root = form.root
    if not root then return end
    local value = object(reply.value)
    if not reply.ok or not value then
        form.error = failure(reply)
        return
    end
    if value.root_ref ~= root.root_ref or value.path ~= form.path then return end
    local folders: {Folder} = {}
    local listed = object(value.folders)
    if listed then
        for _, entry in ipairs(listed :: {unknown}) do
            local folder = object(entry)
            local folder_name = folder and name(folder.name) or nil
            if folder and folder_name and #folders < M.PAGE and #join(form.path, folder_name) <= M.PATH_LIMIT then
                folders[#folders + 1] = {name = folder_name, workspace_id = workspace(folder.workspace_id)}
            end
        end
    end
    form.folders, form.error, form.selected = folders, nil, 1
    form.held = workspace(value.workspace_id)
    local next_after = name(value.next_after)
    form.next_after = next_after
end

local function reset(form: Form)
    form.folders, form.cursor, form.next_after, form.back, form.selected, form.held, form.error = {}, nil, nil, {}, 1, nil, nil
end

function M.forward(form: Form): boolean
    if not form.root or not form.next_after then return false end
    form.back[#form.back + 1] = form.cursor or FIRST_PAGE
    form.cursor = form.next_after
    form.selected = 1
    return true
end

function M.backward(form: Form): boolean
    if not form.root or #form.back == 0 then return false end
    local previous = table.remove(form.back)
    form.cursor = previous ~= FIRST_PAGE and previous or nil
    form.selected = 1
    return true
end

-- Moving past either end of a page of folders asks for the neighbouring page.
function M.move(form: Form, step: integer): string?
    local count = form.root and #form.folders or #form.roots
    local selected = form.selected + step
    if selected < 1 then return M.backward(form) and "page" or nil end
    if selected > count then return M.forward(form) and "page" or nil end
    form.selected = selected
    return "select"
end

function M.select(form: Form, index: integer)
    local count = form.root and #form.folders or #form.roots
    if index >= 1 and index <= count then form.selected = index end
end

-- Enter opens the selected root, or the selected folder of the one shown.
-- True when the form now needs that folder's first page.
function M.open(form: Form): boolean
    if form.step ~= "folder" then return false end
    if not form.root then
        local root = form.roots[form.selected]
        if not root then return false end
        form.root, form.path = root, ""
        reset(form)
        return true
    end
    local folder = form.folders[form.selected]
    if not folder then return false end
    form.path = join(form.path, folder.name)
    reset(form)
    return true
end

-- Up leaves the folder shown for its parent, and a root's top for the list
-- of roots. True when the form now needs the parent's first page.
function M.up(form: Form): boolean
    if form.step ~= "folder" or not form.root then return false end
    if form.path == "" then
        local roots = form.roots
        local left = form.root
        form.root = nil
        reset(form)
        for index, root in ipairs(roots) do
            if left and root.root_ref == left.root_ref then form.selected = index end
        end
        return false
    end
    form.path = form.path:match("^(.*)/[^/]+$") or ""
    reset(form)
    return true
end

-- The folder shown becomes the workspace's folder; the form asks for its label.
function M.use(form: Form): boolean
    if form.step ~= "folder" or not form.root then return false end
    form.step, form.field, form.failure = "details", 1, nil
    suggest(form)
    return true
end

-- Back from the details to the folder; false when the form is already there.
function M.back(form: Form): boolean
    if form.step ~= "details" then return false end
    form.step, form.failure = "folder", nil
    return true
end

-- Field movement: the new folder exists only under a root admitted for writing.
function M.field(form: Form, step: integer)
    local count = M.writable(form) and 2 or 1
    form.field = math.floor(math.max(1, math.min(count, form.field + step)))
end

function M.type_text(form: Form, value: string)
    if form.step ~= "details" or value:find("%c") then return end
    if form.field == 1 then
        if #form.label + #value > M.LABEL_LIMIT then return end
        form.label, form.label_edited = form.label .. value, true
    else
        if #form.new_folder + #value > M.NAME_LIMIT then return end
        form.new_folder = form.new_folder .. value
        suggest(form)
    end
    form.failure = nil
end

local function drop_last(value: string): string
    local cut = #value
    while cut > 1 do
        local byte = value:byte(cut)
        if byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1
    end
    return value:sub(1, cut - 1)
end

function M.erase(form: Form)
    if form.step ~= "details" then return end
    if form.field == 1 then
        if form.label == "" then return end
        form.label, form.label_edited = drop_last(form.label), true
    else
        if form.new_folder == "" then return end
        form.new_folder = drop_last(form.new_folder)
        suggest(form)
    end
    form.failure = nil
end

-- The create request, or nil with the reason when the form cannot make one.
function M.intent(form: Form): model.Intent?
    local root = form.root
    if form.step ~= "details" or not root then return nil end
    local creating = form.new_folder ~= "" and M.writable(form)
    if creating and not name(form.new_folder) then
        form.failure = "A new folder is one name, without / and not . or .."
        return nil
    end
    if not creating and form.held then
        form.failure = (form.path ~= "" and last(form.path) or root.root_ref) .. " is a workspace already; name a new folder inside it"
        return nil
    end
    local subpath = target(form)
    if #subpath > M.PATH_LIMIT then
        form.failure = "The folder path is longer than " .. tostring(M.PATH_LIMIT) .. " bytes"
        return nil
    end
    if form.label == "" then
        form.failure = "Name the workspace"
        return nil
    end
    local request: Object = {label = form.label, root_ref = root.root_ref, subpath = subpath}
    if creating then request.create_directory = true end
    form.failure = nil
    return {target = M.CATALOG .. "create", request = request}
end

-- The created workspace, or nil with the owner's reason kept on the form.
function M.apply_created(form: Form, reply: caller.Reply): model.Summary?
    local created = reply.ok and model.summary(reply.value) or nil
    if not created then
        form.failure = reply.ok and "The owner answered without the new workspace" or failure(reply)
        return nil
    end
    return created
end

return M
