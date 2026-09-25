-- MIT. Ephemeral requests from the currently admitted presenter only.
type Request = {version: integer, op: string, request_id: string, text: string}
type CopyResult = {request_id: string, selected: boolean, text: string, error: string}
local M = {}
function M.request(value: unknown, sender: string, presenter: string, active: boolean): Request?
    if not active or presenter == "" or sender ~= presenter then return nil end
    if type(value) ~= "table" or value.version ~= 1 or value.op ~= "clipboard" then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "op" and key ~= "request_id" and key ~= "text" then return nil end
    end
    local raw_id: unknown = value.request_id
    local raw_text: unknown = value.text
    if type(raw_id) ~= "string" or #raw_id == 0 or #raw_id > 80 or raw_id:find("[%c]") then return nil end
    if type(raw_text) ~= "string" or #raw_text > 8192 then return nil end
    local id: string = raw_id
    local text: string = raw_text
    -- Plain selection may contain tabs/newlines, but no terminal commands.
    if text:find("[%z\1-\8\11-\31\127]") then return nil end
    return {version = 1, op = "clipboard", request_id = id, text = text}
end
function M.copy_id(value: unknown): string?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    for key in pairs(value) do if key ~= "version" and key ~= "request_id" then return nil end end
    local id = value.request_id
    if type(id) ~= "string" or #id == 0 or #id > 80 or id:find("[%c]") then return nil end
    return id
end
function M.copy_result(value: unknown): CopyResult?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "request_id" and key ~= "selected" and key ~= "text" and key ~= "error" then return nil end
    end
    local id = M.copy_id({version = 1, request_id = value.request_id})
    local selected, text, err = value.selected, value.text, value.error
    if not id or type(selected) ~= "boolean" or type(text) ~= "string" or type(err) ~= "string" or #err > 512 then return nil end
    if #text > 8192 or text:find("[%z\1-\8\11-\31\127]") or (not selected and text ~= "") or (err ~= "" and text ~= "") then return nil end
    local wire_bytes = #text
    for i = 1, #text do
        local c = text:byte(i)
        if c == 9 or c == 10 or c == 34 or c == 92 then wire_bytes = wire_bytes + 1
        elseif c == 38 or c == 60 or c == 62 then wire_bytes = wire_bytes + 5
        elseif c == 226 then wire_bytes = wire_bytes + 3 end
    end
    if wire_bytes > 12000 then
        return {request_id = id, selected = true, text = "", error = "Selected text exceeds encoded clipboard limit"}
    end
    return {request_id = id, selected = selected, text = text, error = err}
end
return M
