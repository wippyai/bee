-- MIT. Serializable workspace host state for a same-PID code handoff.
local contract = require("contract")
local inventory = require("inventory")
local decode = require("decode")
local protocol = require("protocol")
local questions = require("questions")
type State = {version: integer, owner: string, workspace_id: string, broker: string,
    catalog_revision: integer, views_revision: integer, catalog: {contract.Descriptor}, views: {inventory.View},
    admitted: {[string]: protocol.Client}, count: integer, assignment_revision: integer,
    questions: questions.State}
local M = {}
local function revision(value: unknown): integer?
    if type(value) ~= "number" or value < 0 or value > 9007199254740990 or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
function M.pack(owner: string, workspace_id: string, broker: string, live: inventory.State,
    admitted: {[string]: protocol.Client}, count: integer, assignment_revision: integer,
    question_state: questions.State): State
    return {version = 1, owner = owner, workspace_id = workspace_id, broker = broker,
        catalog_revision = live.catalog_revision, views_revision = live.views_revision,
        catalog = live.catalog, views = live.views, admitted = admitted, count = count,
        assignment_revision = assignment_revision, questions = question_state}
end
function M.decode(value: unknown, owner: string, workspace_id: string): State?
    if type(value) ~= "table" or value.version ~= 1 or value.owner ~= owner or value.workspace_id ~= workspace_id then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "owner" and key ~= "workspace_id" and key ~= "broker"
            and key ~= "catalog_revision" and key ~= "views_revision" and key ~= "catalog"
            and key ~= "views" and key ~= "admitted" and key ~= "count"
            and key ~= "assignment_revision" and key ~= "questions" then return nil end
    end
    local broker = contract.text(value.broker, 160)
    local catalog_revision, views_revision = revision(value.catalog_revision), revision(value.views_revision)
    local count, assignment_revision = revision(value.count), revision(value.assignment_revision)
    local catalog = decode.catalog(value.catalog)
    local question_state = questions.restore(value.questions, workspace_id)
    if not broker or broker == "" or not catalog_revision or not views_revision or not count
        or count > 8 or not assignment_revision or type(value.catalog) ~= "table"
        or type(value.views) ~= "table" or type(value.admitted) ~= "table"
        or not catalog or not question_state or #value.views > 16 then return nil end
    local views: {inventory.View} = {}
    for index, item in ipairs(value.views) do
        local decoded = inventory.view(item)
        if not decoded or decoded.workspace_id ~= workspace_id then return nil end
        views[index] = decoded
    end
    local admitted: {[string]: protocol.Client} = {}
    local actual = 0
    for pid, item in pairs(value.admitted) do
        if type(pid) ~= "string" or not contract.text(pid, 160) or type(item) ~= "table"
            or item.recipient ~= pid or type(item.connection_id) ~= "string" or item.connection_id == ""
            or not contract.workspace_id(item.display_id) or type(item.renderer) ~= "string"
            or type(item.renderer_generation) ~= "string" or item.renderer_generation == ""
            or type(item.detaching) ~= "boolean" or type(item.rendering) ~= "boolean"
            or type(item.permissions) ~= "table" or type(item.permissions.open) ~= "boolean"
            or type(item.permissions.close) ~= "boolean" or type(item.permissions.control) ~= "boolean"
            or (item.permissions.appearance ~= nil and type(item.permissions.appearance) ~= "boolean") then return nil end
        actual = actual + 1
        if actual > 8 then return nil end
        admitted[pid] = {recipient = pid, connection_id = item.connection_id,
            permissions = {open = item.permissions.open, close = item.permissions.close,
                control = item.permissions.control, appearance = item.permissions.appearance},
            detaching = item.detaching, renderer = item.renderer,
            renderer_generation = item.renderer_generation, rendering = item.rendering,
            display_id = item.display_id}
    end
    if actual ~= count then return nil end
    return {version = 1, owner = owner, workspace_id = workspace_id, broker = broker,
        catalog_revision = catalog_revision, views_revision = views_revision,
        catalog = catalog, views = views, admitted = admitted, count = count,
        assignment_revision = assignment_revision, questions = question_state}
end
return M
