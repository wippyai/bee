-- MIT. Workspace catalog rows project the public durable Sessions directory.
local protocol = require("protocol")
local M = {}
type Object = {[string]: unknown}
function M.project(value: unknown, workspace: string): ({Object}?, string?)
    local page, err = protocol.decode_list_page(value)
    if not page then return nil, err end
    local items: {Object} = {}
    for _, session in ipairs(page.items) do
        if session.workspace == workspace then
            items[#items + 1] = {label = session.title, session = session.session,
                detail = (session.provider or "Agent") .. " · " .. session.activity .. " · " .. session.session}
        end
    end
    return items, nil
end
return M
