local M = {}
M.COMMAND_SECONDS = 3
M.HTTP_SECONDS = 2
M.MCP_SECONDS = 2
function M.seconds(driver: string, point: string): integer?
    if driver == "claude" then return point == "session.start" and M.COMMAND_SECONDS or M.HTTP_SECONDS end
    if driver == "codex" then return M.MCP_SECONDS end
    if driver == "agy" or driver == "muse" or driver == "grok" then return M.COMMAND_SECONDS end
    return nil
end
return M
