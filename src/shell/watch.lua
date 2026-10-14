-- MIT. What a display does when a process it follows goes quiet. The node's
-- supervisor exiting means the node stopped: a display of its own node quits,
-- and a display of another node shows its own node again. The owner exiting
-- means the node restarts its owner, so the display reconnects. A monitor
-- going down means the node became unreachable, not that it stopped (only an
-- exit says that), so the display reconnects and waits for it to serve.
local M = {}

type Followed = {owner: string?, supervisor: string?, target: string, origin: string}
type Action = "stop" | "home" | "reconnect" | "none"

-- lost is the action for an event of kind ("exit" or "monitor_down") from from.
function M.lost(kind: string, from: string, followed: Followed): Action
    if from ~= followed.owner and from ~= followed.supervisor then return "none" end
    if kind == "monitor_down" then return "reconnect" end
    if kind ~= "exit" then return "none" end
    if from == followed.supervisor then
        if followed.target ~= followed.origin then return "home" end
        return "stop"
    end
    return "reconnect"
end

return M
