local M = {}
M.COMMAND_SECONDS = 3
M.HTTP_SECONDS = 2
M.MCP_SECONDS = 2
-- A PermissionRequest hook waits for a person. A host answers within ten
-- minutes, an expired request included, so the hook stays open past that.
M.PERMISSION_SECONDS = 650
return M
