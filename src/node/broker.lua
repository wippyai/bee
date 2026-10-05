-- MIT. The bee.app messages an app sends the node owner, its broker. Each is
-- accepted only from the app's own process carrying its launch token; the
-- owner checks those against the instance the message names.
local interaction = require("interaction")
local arguments = require("arguments")
local bounds = require("bounds")

local M = {}

M.READY = "bee.app.ready"
M.TITLE = "bee.app.title"
M.CLOSE = "bee.app.close"
M.CLOSE_REPLY = "bee.app.close.reply"
M.CLOSE_RESULT = "bee.app.close.result"
M.QUERY = "bee.app.query"
M.QUERY_RESULT = "bee.app.query.result"
M.CHECKPOINT = "bee.app.checkpoint"
M.CHECKPOINT_RESULT = "bee.app.checkpoint_result"
M.REQUEST = "bee.app.request"
M.NAVIGATE = "bee.app.navigate"
M.TOPICS = {M.READY, M.TITLE, M.CLOSE_REPLY, M.QUERY, M.CHECKPOINT, M.REQUEST}

type Object = {[string]: unknown}
type Close = {request_id: string, action: "accept" | "cancel" | "confirm", title: string, message: string, accept: string}
type Checkpoint = {request_id: string, resume_schema: string, resume_state: string}
type Open = {request_id: string, definition_id: string, arguments: {string}}

local function text(value: unknown, limit: integer): string?
    if type(value) ~= "string" or value == "" or #value > limit or value:find("%c") then return nil end
    return value
end

-- authentic reports whether value names the instance and carries its launch
-- token; a navigation request names the instance it comes from.
function M.authentic(value: unknown, instance_id: string, token: string): boolean
    local object = bounds.object(value)
    if not object or object.version ~= 1 or object.launch_token ~= token then return false end
    local named = object.instance_id
    if named == nil then named = object.source_instance_id end
    return named == instance_id
end

function M.ready(value: unknown): boolean?
    local object = bounds.object(value)
    if not object then return nil end
    return object.negotiate_close == true
end

function M.title(value: unknown): string?
    local object = bounds.object(value)
    local title = object and object.title
    if type(title) ~= "string" or #title > 80 or title:find("%c") then return nil end
    return title
end

function M.close_reply(value: unknown): Close?
    local object = bounds.object(value)
    if not object then return nil end
    local request_id = text(object.request_id, 80)
    local action = object.action
    if not request_id or (action ~= "accept" and action ~= "cancel" and action ~= "confirm") then return nil end
    local title = text(object.title, 80) or "Close application?"
    local message = type(object.message) == "string" and #object.message <= 512 and not object.message:find("%c") and object.message or ""
    local accept = text(object.accept, 24) or "Close"
    return {request_id = request_id, action = action, title = title, message = message, accept = accept}
end

-- query is the dialog an app asks for, as the interaction spec it names.
function M.query(value: unknown): interaction.Spec?
    return interaction.spec(value)
end

function M.checkpoint(value: unknown): Checkpoint?
    local object = bounds.object(value)
    if not object then return nil end
    local request_id = text(object.request_id, 80)
    local schema, state = object.resume_schema, object.resume_state
    if not request_id or type(schema) ~= "string" or #schema > 80 or type(state) ~= "string" or #state > 65536 then return nil end
    return {request_id = request_id, resume_schema = schema, resume_state = state}
end

function M.open(value: unknown): Open?
    local object = bounds.object(value)
    if not object or object.op ~= "open" then return nil end
    local request_id = text(object.request_id, 80)
    local definition = bounds.id(object.definition_id)
    local args = arguments.decode(object.arguments)
    if not request_id or not definition or not args then return nil end
    return {request_id = request_id, definition_id = definition, arguments = args}
end

return M
