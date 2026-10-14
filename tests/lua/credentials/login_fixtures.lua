-- MIT. Admission readers standing in for governance's approved driver logins.
local M = {}
function M.approved(): ({{[string]: string}}?, string?)
    return {{provider = "gem", format = "bee.driver.gem.credentials:credential_format", path = ".gem/creds.json"}}, nil
end
function M.claiming(): ({{[string]: string}}?, string?)
    return {{provider = "claude", format = "bee.driver.claude.credentials:credential_format", path = ".claude/.credentials.json"}}, nil
end
return M
