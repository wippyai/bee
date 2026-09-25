-- MIT. Select owned checkpoints only after host authorization of an open.
local records = require("records")
local inventory = require("inventory")
type Resume = {view_id: string, instance_id: string, thread_id: string?, schema: string, state: string}
local M = {}
function M.select(saved: {records.Record}, live: inventory.State, definition_id: string,
    reserved: {[string]: boolean}, requested_thread_id: string?): Resume?
    for _, record in ipairs(saved) do
        if record.definition_id == definition_id and (requested_thread_id == nil or requested_thread_id == record.thread_id)
            and not reserved[record.instance_id] then
            local running = false
            for _, view in ipairs(live.views) do
                if view.instance_id == record.instance_id or view.view_id == record.id then running = true; break end
            end
            if not running then
                return {view_id = record.id, instance_id = record.instance_id, thread_id = record.thread_id,
                    schema = record.resume_schema, state = record.resume_state}
            end
        end
    end
    return nil
end
return M
