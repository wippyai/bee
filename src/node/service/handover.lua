-- MIT. Node application instance state and handover decoding.
local tty = require("tty")
local uuid = require("uuid")
local client = require("client")
local confirmation = require("confirmation")
local M = {}
-- terminal marks an app that renders a terminal emulator, which takes the
-- theme's terminal page colors.
-- A dialog an app asks the display to show: request_id is the owner's, the
-- app's own id comes back in its answer; closing marks the confirmation an
-- app asked for before it closes.
type Dialog = {request_id: string, client_request_id: string, kind: string, title: string, message: string,
    accept: string, initial: string, closing: boolean, target: {[string]: unknown}?, confirmation: confirmation.Pending?}
-- token is the launch token the app's broker messages carry; negotiate marks
-- an app that answers close requests; closing is the close request it is
-- answering; args are what it was opened with, kept with its checkpoint;
-- request is the agent open request that started it, so a retry finds it.
type AppAlias = {stable: string, instance: string, workspace_id: string, definition_id: string}
type Instance = {review: client.Review?, id: string, app: string, title: string, desktop: string, workspace: string, view: tty.Viewport, pid: string, terminal: boolean,
    execution_id: string, token: string, negotiate: boolean, closing: string?, dialog: Dialog?, args: {[string]: unknown}, resume_schema: string,
    singleton: boolean, revision: string?, definition: string?, update_target: string?, relaunch: boolean?, alias: AppAlias, request: string?}
type SavedInstance = {review: client.Review?, id: string, app: string, title: string, desktop: string, workspace: string, handle: string, pid: string, terminal: boolean,
    execution_id: string, token: string, negotiate: boolean, closing: string?, dialog: Dialog?, args: {[string]: unknown}, resume_schema: string,
    singleton: boolean, revision: string?, definition: string?, update_target: string?, relaunch: boolean?, alias: AppAlias?, request: string?}
type SavedWatcher = {pid: string, desktop: string}
type UpdateProblem = {app: string, definition: string?, reason: string}
type Saved = {instances: {SavedInstance}, watchers: {SavedWatcher}, revision: integer, alerts: {client.Alert}, update_problems: {[string]: UpdateProblem}}
-- words are the string arguments an open passed, in order.
local function words(app_args: {[string]: unknown}): {string}
    local found: {string} = {}
    local given = app_args.arguments
    if type(given) == "table" then
        for _, word in ipairs(given) do
            if type(word) == "string" then found[#found + 1] = word end
        end
    end
    return found
end

local function saved_confirmation(value: unknown): (confirmation.Pending?, boolean)
    if value == nil then return nil, true end
    if type(value) ~= "table" or type(value.view) ~= "table" or type(value.target) ~= "string"
        or type(value.action) ~= "string" or type(value.presentation) ~= "string" then
        return nil, false
    end
    return {view = value.view, target = value.target, action = value.action, presentation = value.presentation}, true
end

-- saved_dialog decodes the dialog a predecessor handed over; ok is false when
-- the record is malformed.
local function saved_dialog(value: unknown): (Dialog?, boolean)
    if value == nil then return nil, true end
    if type(value) ~= "table" or type(value.request_id) ~= "string" or type(value.client_request_id) ~= "string"
        or type(value.kind) ~= "string" or type(value.title) ~= "string" or type(value.message) ~= "string"
        or type(value.accept) ~= "string" or type(value.initial) ~= "string" or type(value.closing) ~= "boolean" then
        return nil, false
    end
    local target = value.target
    if target ~= nil and type(target) ~= "table" then return nil, false end
    local pending, pending_ok = saved_confirmation(value.confirmation)
    if not pending_ok then return nil, false end
    return {request_id = value.request_id, client_request_id = value.client_request_id, kind = value.kind,
        title = value.title, message = value.message, accept = value.accept, initial = value.initial,
        closing = value.closing, target = target, confirmation = pending}, true
end

-- restored is the instance a predecessor handed over as item, reattached to
-- view under alias with its decoded dialog.
local function restored(item: {[string]: unknown}, view: tty.Viewport, alias: AppAlias, dialog: Dialog?): Instance
    return {review = client.review(item.review), id = tostring(item.id), app = tostring(item.app), title = tostring(item.title),
        desktop = tostring(item.desktop), workspace = type(item.workspace) == "string" and item.workspace or "",
        view = view, pid = tostring(item.pid), terminal = item.terminal == true,
        execution_id = type(item.execution_id) == "string" and item.execution_id or tostring(uuid.v7()),
        token = type(item.token) == "string" and item.token or "", negotiate = item.negotiate == true,
        closing = type(item.closing) == "string" and item.closing or nil, dialog = dialog,
        args = type(item.args) == "table" and item.args or {},
        resume_schema = type(item.resume_schema) == "string" and item.resume_schema or "",
        singleton = item.singleton == true, revision = type(item.revision) == "string" and item.revision or nil,
        definition = type(item.definition) == "string" and item.definition or nil,
        update_target = type(item.update_target) == "string" and item.update_target or nil,
        relaunch = item.relaunch == true or nil, alias = alias, request = type(item.request) == "string" and item.request or nil}
end

-- describe is the wire form of an instance.
local function describe(instance: Instance): {[string]: unknown}
    return {review = instance.review, id = instance.id, app = instance.app, title = instance.title, desktop = instance.desktop, pid = instance.pid, execution_id = instance.execution_id}
end

-- dialog_of is the wire form of an instance's pending dialog.
local function dialog_of(instance: Instance): {[string]: unknown}?
    local dialog = instance.dialog
    if not dialog then return nil end
    return {id = instance.id, request_id = dialog.request_id, kind = dialog.kind, title = dialog.title,
        message = dialog.message, accept = dialog.accept, initial = dialog.initial}
end

M.restored = restored
M.describe = describe
M.dialog_of = dialog_of
M.words = words
M.saved_confirmation = saved_confirmation
M.saved_dialog = saved_dialog
return M
