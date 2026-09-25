-- MIT. The Workspaces create flow, pure: a folder picked with the shared
-- folder picker over the roots the host admits, then a label and, under a
-- root admitted for writing, an optional new folder made inside the chosen
-- one. Every owner text is bounded.
local text = require("text")
local caller = require("caller")
local model = require("model")
local folder_picker = require("folder_picker")

-- step: "folder" picks the root and folder, "details" names the workspace.
-- field: 1 the label, 2 the new folder.
type Form = {step: string, picker: folder_picker.Picker, field: integer, label: string, label_edited: boolean,
    new_folder: string, failure: string?}
type Object = {[string]: unknown}

local M = {}
M.ARGUMENT = "create"
M.CATALOG = folder_picker.CATALOG
M.LABEL_LIMIT = 240

function M.new(): Form
    return {step = "folder", picker = folder_picker.new(), field = 1, label = "", label_edited = false, new_folder = "", failure = nil}
end

-- The viewer opens with the form when its launch names the create flow.
function M.requested(arguments: {string}): boolean
    return arguments[1] == M.ARGUMENT
end

local function failure(reply: caller.Reply): string
    local fault = reply.error
    if not fault then return "The owner did not answer" end
    return text.bound(fault.code .. ": " .. fault.message, 200)
end

local function last(path: string): string
    return path:match("([^/]+)$") or path
end

function M.writable(form: Form): boolean
    return folder_picker.writable(form.picker)
end

-- The folder the workspace will hold: the chosen one, or the new folder
-- inside it.
local function target(form: Form): string
    if form.new_folder ~= "" and M.writable(form) then return folder_picker.join(form.picker.path, form.new_folder) end
    return form.picker.path
end

-- A label nobody typed follows the folder the workspace will hold.
local function suggest(form: Form)
    if form.label_edited then return end
    local root = form.picker.root
    local folder = target(form)
    form.label = folder ~= "" and text.bound(last(folder), M.LABEL_LIMIT) or (root and root.root_ref or "")
end

-- The folder shown becomes the workspace's folder; the form asks for its label.
function M.use(form: Form): boolean
    if form.step ~= "folder" or not form.picker.root then return false end
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
        if #form.new_folder + #value > folder_picker.NAME_LIMIT then return end
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
    local root = form.picker.root
    if form.step ~= "details" or not root then return nil end
    local creating = form.new_folder ~= "" and M.writable(form)
    if creating and not folder_picker.name(form.new_folder) then
        form.failure = "A new folder is one name, without / and not . or .."
        return nil
    end
    if not creating and form.picker.held then
        form.failure = (form.picker.path ~= "" and last(form.picker.path) or root.root_ref) .. " is a workspace already; name a new folder inside it"
        return nil
    end
    local subpath = target(form)
    if #subpath > folder_picker.PATH_LIMIT then
        form.failure = "The folder path is longer than " .. tostring(folder_picker.PATH_LIMIT) .. " bytes"
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
