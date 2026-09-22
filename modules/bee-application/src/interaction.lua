-- MIT. Bounded interaction values; identity checks belong to the receiving owner.
type Kind = "confirm" | "text"
type Spec = {request_id: string, id: string, instance_id: string, kind: Kind,
    title: string, message: string, accept: string, initial: string}
type Wire = {version: integer, request_id: string, id: string, instance_id: string, kind: Kind,
    title: string, message: string, accept: string, initial: string}
type Response = {request_id: string, id: string, instance_id: string, action: "accept" | "cancel", value: string}
type Result = {version: integer, request_id: string, id: string, instance_id: string, error_code: string, error: string}
local M = {}
local function text(value: unknown, limit: integer, required: boolean): string?
    if type(value) ~= "string" or #value > limit or value:find("%c") or (required and value == "") then return nil end
    return value
end
function M.spec(value: unknown): Spec?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local kind = value.kind
    if kind ~= "confirm" and kind ~= "text" then return nil end
    local request_id = text(value.request_id, 80, true)
    local id, instance_id = text(value.id, 80, true), text(value.instance_id, 80, true)
    local title, message = text(value.title, 80, true), text(value.message, 512, false)
    local accept, initial = text(value.accept, 24, true), text(value.initial or "", 256, false)
    if not request_id or not id or not instance_id or not title or not message or not accept or not initial then return nil end
    if kind == "confirm" and initial ~= "" then return nil end
    return {request_id = request_id, id = id, instance_id = instance_id, kind = kind,
        title = title, message = message, accept = accept, initial = initial}
end
function M.wire(value: Spec): Wire
    return {version = 1, request_id = value.request_id, id = value.id, instance_id = value.instance_id,
        kind = value.kind, title = value.title, message = value.message, accept = value.accept, initial = value.initial}
end
function M.response(value: unknown): Response?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local action = value.action
    if action ~= "accept" and action ~= "cancel" then return nil end
    local request_id = text(value.request_id, 80, true)
    local id, instance_id = text(value.id, 80, true), text(value.instance_id, 80, true)
    local answer = text(value.value or "", 256, false)
    if not request_id or not id or not instance_id or not answer then return nil end
    if action == "cancel" and answer ~= "" then return nil end
    return {request_id = request_id, id = id, instance_id = instance_id, action = action, value = answer}
end
function M.result(value: unknown): Result?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local request_id, id = text(value.request_id, 80, true), text(value.id, 80, true)
    local instance_id, code = text(value.instance_id, 80, true), text(value.error_code, 80, false)
    if not request_id or not id or not instance_id or not code or type(value.error) ~= "string" or #value.error > 4096 then return nil end
    return {version = 1, request_id = request_id, id = id, instance_id = instance_id, error_code = code, error = value.error}
end
function M.shutdown(value: unknown): Spec?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local spec = M.spec(value.shutdown)
    if not spec or spec.id ~= "bee.workspace:shutdown" or spec.instance_id ~= "workspace" or spec.kind ~= "confirm" then return nil end
    return spec
end
function M.snapshot(value: unknown): {Spec}?
    if type(value) ~= "table" or value.version ~= 1 or type(value.items) ~= "table" then return nil end
    local count = 0
    for key in pairs(value.items) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 16 then return nil end
        count = count + 1
    end
    local result: {Spec} = {}
    local views: {[string]: boolean} = {}
    for i = 1, count do
        local item = M.spec(value.items[i])
        if not item or views[item.id] then return nil end
        views[item.id] = true
        result[#result + 1] = item
    end
    return result
end
return M
