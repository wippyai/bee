local channel = require("channel")
local bounds = require("bounds")
local agents = require("agents")
local sessions_protocol = require("sessions_protocol")
local M = {}
type IO = {
    directory: (string?, string?, boolean) -> ({sessions_protocol.SessionSnapshot}?, string?),
    peers: () -> (unknown, unknown),
    workspace: (string) -> agents.Workspace?,
}
function M.load(io: IO, workspace_id: string, workspace_filter: string?, closed_requested: boolean): ({sessions_protocol.SessionSnapshot}, {[string]: agents.Workspace}, string?)
    local completed = channel.new(3)
    local local_rows: {sessions_protocol.SessionSnapshot}? = nil
    local load_error: string? = nil
    local peer_raw: unknown = nil
    local peer_error: unknown = nil
    local own: agents.Workspace? = nil
    coroutine.spawn(function()
        local_rows, load_error = io.directory(nil, workspace_filter, closed_requested)
        completed:send(true)
    end)
    coroutine.spawn(function()
        peer_raw, peer_error = io.peers()
        completed:send(true)
    end)
    coroutine.spawn(function()
        own = io.workspace(workspace_id)
        completed:send(true)
    end)
    for _ = 1, 3 do completed:receive() end
    local peer_reply = bounds.object(peer_raw)
    local peer_value = peer_reply and bounds.object(peer_reply.value)
    local peers = peer_value and bounds.dense_list(peer_value.items, 16, "peer bees")
    if peer_error then load_error = tostring(peer_error) end
    local rows = local_rows or {}
    for _, raw in ipairs(peers or {}) do
        local peer = bounds.object(raw)
        local node, scope = peer and bounds.id(peer.node), peer and bounds.id(peer.scope)
        if node and scope then
            local remote, err = io.directory(node, nil, closed_requested)
            if remote then
                for _, row in ipairs(remote) do row.node, row.peer_scope = node, scope; rows[#rows + 1] = row end
            else load_error = err end
        end
    end
    table.sort(rows, function(a: sessions_protocol.SessionSnapshot, b: sessions_protocol.SessionSnapshot): boolean
        if a.node ~= b.node then return (a.node or "") < (b.node or "") end
        return a.execution.evidence_at > b.execution.evidence_at
    end)
    local names: {[string]: agents.Workspace} = {}
    if own then names[workspace_id] = own end
    for _, row in ipairs(rows or {}) do
        local id = agents.home(row.session)
        if id and not row.node and not names[id] then names[id] = io.workspace(id) end
    end
    return rows, names, load_error
end
return M
